# mailsearch-mcp — read-only hybrid mail search exposed as an MCP stdio server.
#
# Three tools, all read-only:
#   search_mail(query, top_k, mode, folder, date_from, date_to, sender)
#       -> ranked metadata + snippet (NO bodies). `mode` picks the retrieval
#          strategy: "keyword" (notmuch only, the DEFAULT — exact/structured),
#          "semantic" (sqlite-vec KNN only — fuzzy "about X" recall), or "hybrid"
#          (both, fused via Reciprocal Rank Fusion). Semantic is OPT-IN so a
#          precise keyword query isn't diluted by embedding noise.
#   find_similar(message_id, top_k, folder, date_from, date_to)
#       -> "more like this": messages semantically nearest to an existing one,
#          via that message's STORED vector (no re-embed). Seed must be embedded.
#   get_message(message_id)
#       -> one full body (text/plain preferred, HTML stripped), attachment
#          FILENAMES only, length-capped.
#
# Runs on doc2 as the unprivileged `mailsearch-ro` user (the SSH forced command
# target). Opens notmuch + sqlite read-only. NO write/compose/tag/delete tools.
# Logs ONLY to stderr (stdout is reserved for JSON-RPC) and NEVER logs the query
# string or message bodies (the journal ships to Loki, readable by the fleet).
#
# Plan:    docs/plans/2026-06-23-001-feat-mailarchive-search-plan.md (U5)
# Runbook: docs/wiki/services/mailsearch.md
#
# DEPLOY-TIME VERIFY: first-cut, validated by `nix flake check` (eval only).
# Confirm the FastMCP API, notmuch JSON shapes, and sqlite-vec KNN at deploy.
# find_similar reads a stored vector back out of vec0 (`SELECT v.embedding`) and
# feeds it straight into a fresh `embedding MATCH ?` KNN — verify the returned
# blob is byte-compatible with the probe param (a str/JSON fallback is handled).
{pkgs}: let
  py = pkgs.python3Packages;
in
  pkgs.writers.writePython3Bin "mailsearch-mcp" {
    libraries = [
      py.apsw
      py.sqlite-vec
      py.html2text
      py.mcp
    ];
    flakeIgnore = ["E501" "E402"];
  } ''
    """Read-only hybrid mail search over an MCP stdio transport.

    Environment:
      NOTMUCH_CONFIG          notmuch config (points at the read-only Xapian DB)
      NOTMUCH_BIN             notmuch binary path (default "notmuch")
      MAILSEARCH_VECTOR_DB    sqlite-vec DB (opened read-only)
      MAILSEARCH_EMBED_URL    llama-server /v1/embeddings (for the query vector)
      MAILSEARCH_EMBED_MODEL  model name (default "nomic")
      MAILSEARCH_TOPK_CAP     hard cap on top_k (default 50)
      MAILSEARCH_BODY_CAP     get_message body char cap (default 20000)
      MAILSEARCH_DIM          embedding dimension (default 768)
    """
    import datetime
    import json
    import os
    import subprocess
    import sys
    import urllib.request

    import apsw
    import html2text
    import sqlite_vec
    from mcp.server.fastmcp import FastMCP

    NOTMUCH = os.environ.get("NOTMUCH_BIN", "notmuch")
    VECTOR_DB = os.environ["MAILSEARCH_VECTOR_DB"]
    EMBED_URL = os.environ["MAILSEARCH_EMBED_URL"]
    EMBED_MODEL = os.environ.get("MAILSEARCH_EMBED_MODEL", "nomic")
    TOPK_CAP = int(os.environ.get("MAILSEARCH_TOPK_CAP", "50"))
    BODY_CAP = int(os.environ.get("MAILSEARCH_BODY_CAP", "20000"))
    DIM = int(os.environ.get("MAILSEARCH_DIM", "768"))
    RRF_K = 60

    mcp = FastMCP("mail-search")


    def log(msg):
        # stderr only; never the query text or bodies.
        sys.stderr.write(f"mailsearch-mcp: {msg}\n")
        sys.stderr.flush()


    def notmuch_json(args):
        # Decode tolerantly — notmuch can emit non-UTF-8 bytes from malformed
        # headers, which would otherwise crash the tool on a single bad message.
        out = subprocess.run([NOTMUCH, *args], check=True, capture_output=True).stdout
        text = out.decode("utf-8", errors="replace")
        return json.loads(text) if text.strip() else []


    def find_message(docs):
        # See mailsearch-indexer: descend the notmuch show forest and return the
        # first non-empty message dict (not the empty thread-root stub).
        if isinstance(docs, list):
            for item in docs:
                found = find_message(item)
                if found is not None:
                    return found
            return None
        if isinstance(docs, dict):
            return docs if (docs.get("id") or docs.get("headers")) else None
        return None


    def db_ro():
        db = apsw.Connection(VECTOR_DB, flags=apsw.SQLITE_OPEN_READONLY)
        db.setbusytimeout(5000)
        db.enableloadextension(True)
        db.loadextension(sqlite_vec.loadable_path())
        db.enableloadextension(False)
        return db


    def embed_query(text):
        payload = json.dumps({
            "model": EMBED_MODEL,
            "input": ["search_query: " + text],
        }).encode()
        req = urllib.request.Request(
            EMBED_URL, data=payload,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read())
        return data["data"][0]["embedding"]


    def notmuch_query(query, folder, date_from, date_to, sender):
        terms = [query.strip()] if query and query.strip() else []
        if folder:
            # Strip quotes so a crafted value can't break out of the quoted
            # term and inject notmuch operators (folder scoping must hold).
            terms.append('folder:"' + folder.replace('"', "") + '"')
        if sender:
            terms.append('from:"' + sender.replace('"', "") + '"')
        if date_from and date_to:
            terms.append(f"date:{date_from}..{date_to}")
        elif date_from:
            terms.append(f"date:{date_from}..")
        elif date_to:
            terms.append(f"date:..{date_to}")
        return " and ".join(t for t in terms if t) or "*"


    def keyword_ids(query, folder, date_from, date_to, sender, limit):
        q = notmuch_query(query, folder, date_from, date_to, sender)
        try:
            ids = notmuch_json([
                "search", "--output=messages", "--format=json",
                f"--limit={limit}", "--sort=newest-first", q,
            ])
        except (subprocess.CalledProcessError, json.JSONDecodeError, ValueError) as e:
            # Catch JSON-decode/value errors too: an unhandled exception would
            # let FastMCP emit a traceback whose locals leak the query string to
            # Loki (fleet-readable). Log only the exception type, never the query.
            log(f"notmuch keyword search failed ({type(e).__name__})")
            return []
        return ids


    def semantic_knn(db, qvec_blob, folder, limit, exclude_rowid=None):
        # Low-level KNN over the vector store. qvec_blob is a serialized float32
        # blob — either freshly serialized from a query embedding (search_mail)
        # or a vector read straight back out of vec0 (find_similar / "more like
        # this"). Returns [(rowid, message_id), ...] nearest-first. The date
        # filter is applied post-hoc against notmuch below (vec0 has no date
        # predicate here); folder is a real partition/column filter.
        clauses, params = ["embedding MATCH ?", "k = ?"], [qvec_blob, limit]
        if folder:
            clauses.append("folder = ?")
            params.append(folder)
        sql = (
            "SELECT v.message_rowid, m.message_id, v.distance "
            "FROM vec_messages v JOIN messages m ON m.rowid = v.message_rowid "
            "WHERE " + " AND ".join(clauses) + " ORDER BY v.distance"
        )
        try:
            rows = db.execute(sql, params).fetchall()
        except apsw.Error as e:
            log(f"sqlite-vec KNN failed: {e}")
            return []
        return [(rowid, mid) for rowid, mid, _dist in rows if rowid != exclude_rowid]


    def semantic_ids(db, qvec, folder, limit):
        return [mid for _rowid, mid in
                semantic_knn(db, sqlite_vec.serialize_float32(qvec), folder, limit)]


    def rrf(*ranked_lists):
        scores = {}
        for lst in ranked_lists:
            for rank, mid in enumerate(lst, 1):
                scores[mid] = scores.get(mid, 0.0) + 1.0 / (RRF_K + rank)
        return [mid for mid, _ in sorted(scores.items(), key=lambda kv: -kv[1])]


    def folder_of(path):
        marker = "/Email/"
        i = path.find(marker)
        if i < 0:
            return ""
        parts = [p for p in path[i + len(marker):].split("/") if p]
        # drop the trailing cur|new|tmp + filename
        return "/".join(parts[:-2]) if len(parts) > 2 else (parts[0] if parts else "")


    def to_epoch(s, end=False):
        # YYYY-MM-DD -> UTC epoch (end=True -> end of that day).
        try:
            d = datetime.datetime.strptime(s, "%Y-%m-%d").replace(
                tzinfo=datetime.timezone.utc)
        except (ValueError, TypeError):
            return None
        if end:
            d = d + datetime.timedelta(days=1, seconds=-1)
        return int(d.timestamp())


    def notmuch_meta(mid):
        # Display metadata + snippet straight from notmuch (the keyword DB has
        # every message) — NOT the vector store's messages table, which would
        # be blank for keyword hits not yet embedded.
        try:
            docs = notmuch_json([
                "show", "--format=json", "--entire-thread=false",
                "--body=true", "--format-version=5", f"id:{mid}",
            ])
        except subprocess.CalledProcessError:
            return None
        node = find_message(docs)
        if not isinstance(node, dict):
            return None
        headers = node.get("headers", {}) or {}
        path = node.get("filename")
        if isinstance(path, list):
            path = path[0] if path else ""
        snippet = " ".join(extract_plain(node.get("body", [])).split())[:240]
        return {
            "from": headers.get("From", ""),
            "subject": headers.get("Subject", ""),
            "date": int(node.get("timestamp", 0) or 0),
            "folder": folder_of(path or ""),
            "snippet": snippet,
        }


    def extract_plain(part):
        out = []
        stack = [part]
        while stack:
            p = stack.pop()
            if isinstance(p, list):
                stack.extend(p)
            elif isinstance(p, dict):
                # An attachment that happens to be text/plain is not body text.
                if p.get("filename") or (p.get("content-disposition") or "").lower() == "attachment":
                    continue
                ctype = (p.get("content-type") or "").lower()
                content = p.get("content")
                if ctype == "text/plain" and isinstance(content, str):
                    out.append(content)
                elif isinstance(content, list):
                    stack.extend(content)
        return "\n".join(out)


    VALID_MODES = ("keyword", "semantic", "hybrid")


    @mcp.tool()
    def search_mail(query: str, top_k: int = 10, mode: str = "keyword",
                    folder: str | None = None,
                    date_from: str | None = None, date_to: str | None = None,
                    sender: str | None = None) -> dict:
        """Search the personal mail archive. Returns ranked metadata + a short
        snippet only (never full bodies — use get_message for that).

        Args:
          query: a notmuch query string (from:/to:/subject:/body:/attachment:,
            "quoted phrases", bare words, and/or/not) for keyword/hybrid, or
            plain natural-language prose for semantic.
          top_k: max results (capped server-side).
          mode: retrieval strategy — DEFAULT "keyword". Semantic is opt-in.
            - "keyword": notmuch exact/structured search only. Precise, reliable,
              works even if the embedding server is down. Your workhorse.
            - "semantic": embedding KNN only — fuzzy "the email ABOUT X" recall
              for when you can't name the keyword. Newsletter-noisy and misses
              un-embedded (older, during bootstrap) mail; reach for it only when
              keyword genuinely can't express the concept.
            - "hybrid": run both legs and fuse with Reciprocal Rank Fusion — for
              a query carrying BOTH exact terms and fuzzy intent.
          folder: optional Maildir folder filter (e.g. "work/INBOX").
          date_from, date_to: optional YYYY-MM-DD bounds.
          sender: optional From: substring filter (applied in every mode).
        """
        mode = (mode or "keyword").strip().lower()
        if mode not in VALID_MODES:
            log(f"unknown mode, falling back to keyword (got {mode!r})")
            mode = "keyword"
        k = max(1, min(int(top_k), TOPK_CAP))
        over = min(TOPK_CAP, k * 5)
        db = db_ro()
        kw = []
        if mode in ("keyword", "hybrid"):
            kw = keyword_ids(query, folder, date_from, date_to, sender, over)
        sem = []
        if mode in ("semantic", "hybrid") and query and query.strip():
            try:
                sem = semantic_ids(db, embed_query(query), folder, over)
            except Exception as e:  # noqa: BLE001
                # Keyword still stands (hybrid); semantic-only just yields nothing.
                log(f"semantic leg unavailable: {type(e).__name__}")
        if mode == "keyword":
            ranked = kw
        elif mode == "semantic":
            ranked = sem
        else:
            ranked = rrf(kw, sem)
        ef = to_epoch(date_from) if date_from else None
        et = to_epoch(date_to, end=True) if date_to else None
        sender_lc = sender.lower() if sender else None
        results = []
        for mid in ranked:
            if len(results) >= k:
                break
            m = notmuch_meta(mid)
            if m is None:
                continue
            # Enforce date + sender uniformly: the semantic leg filters on
            # neither, so an out-of-range or wrong-sender neighbour could
            # otherwise slip into semantic/hybrid results.
            if (ef is not None and m["date"] < ef) or (et is not None and m["date"] > et):
                continue
            if sender_lc and sender_lc not in m["from"].lower():
                continue
            results.append({
                "message_id": mid,
                "from": m["from"],
                "subject": m["subject"],
                "date": m["date"],
                "folder": m["folder"],
                "snippet": m["snippet"],
            })
        log(f"search_mail mode={mode} keyword={len(kw)} semantic={len(sem)} returned={len(results)}")
        return {"results": results}


    @mcp.tool()
    def find_similar(message_id: str, top_k: int = 10, folder: str | None = None,
                     date_from: str | None = None,
                     date_to: str | None = None) -> dict:
        """'More like this': find messages semantically nearest to an existing
        one, using that message's already-stored embedding — no re-embedding and
        no query text. Anchor on one solid hit (from search_mail), then pull the
        cluster around it without having to guess the corpus vocabulary.

        The seed must already be embedded (recent-ish mail during the one-time
        bootstrap). If it isn't, returns {"error": ...} with empty results — fall
        back to a keyword search on the seed's subject/sender.

        Args:
          message_id: the seed message's Message-ID (from search_mail results).
          top_k: max neighbours (capped server-side; excludes the seed itself).
          folder: optional Maildir folder filter.
          date_from, date_to: optional YYYY-MM-DD bounds.
        """
        k = max(1, min(int(top_k), TOPK_CAP))
        over = min(TOPK_CAP, k * 5)
        db = db_ro()
        try:
            row = db.execute(
                "SELECT v.message_rowid, v.embedding "
                "FROM vec_messages v JOIN messages m ON m.rowid = v.message_rowid "
                "WHERE m.message_id = ?", (message_id,),
            ).fetchone()
        except apsw.Error as e:
            log(f"find_similar seed lookup failed: {e}")
            return {"error": "seed lookup failed", "results": []}
        if row is None:
            return {"error": "seed not embedded (no vector for this message_id)",
                    "results": []}
        seed_rowid, seed_vec = row
        # seed_vec is the raw serialized float32 blob straight from vec0, fed back
        # as the KNN probe. Some sqlite-vec builds hand it back as JSON text —
        # re-serialize in that case so the probe param is always a float32 blob.
        if isinstance(seed_vec, str):
            seed_vec = sqlite_vec.serialize_float32(json.loads(seed_vec))
        # Ask for one extra so we still return k after dropping the seed itself.
        neighbours = semantic_knn(db, seed_vec, folder, over + 1,
                                  exclude_rowid=seed_rowid)
        ef = to_epoch(date_from) if date_from else None
        et = to_epoch(date_to, end=True) if date_to else None
        results = []
        for _rowid, mid in neighbours:
            if len(results) >= k:
                break
            m = notmuch_meta(mid)
            if m is None:
                continue
            if (ef is not None and m["date"] < ef) or (et is not None and m["date"] > et):
                continue
            results.append({
                "message_id": mid,
                "from": m["from"],
                "subject": m["subject"],
                "date": m["date"],
                "folder": m["folder"],
                "snippet": m["snippet"],
            })
        log(f"find_similar neighbours={len(neighbours)} returned={len(results)}")
        return {"results": results}


    @mcp.tool()
    def get_message(message_id: str) -> dict:
        """Return one full message (gated): headers, plain-text body (HTML
        stripped, length-capped) and attachment FILENAMES only — never payloads.
        """
        try:
            docs = notmuch_json([
                "show", "--format=json", "--entire-thread=false",
                "--include-html", "--format-version=5", f"id:{message_id}",
            ])
        except subprocess.CalledProcessError:
            return {"error": "not found"}
        node = find_message(docs)
        if not isinstance(node, dict):
            return {"error": "not found"}
        headers = node.get("headers", {}) or {}
        plain = extract_plain(node.get("body", []))
        if not plain:
            h = html2text.HTML2Text()
            h.ignore_links = True
            plain = h.handle(extract_html(node.get("body", [])))
        attachments = extract_attachments(node.get("body", []))
        return {
            "message_id": message_id,
            "from": headers.get("From", ""),
            "to": headers.get("To", ""),
            "subject": headers.get("Subject", ""),
            "date": headers.get("Date", ""),
            "attachments": attachments,
            "body": plain[:BODY_CAP],
            "truncated": len(plain) > BODY_CAP,
        }


    def extract_html(part):
        out, stack = [], [part]
        while stack:
            p = stack.pop()
            if isinstance(p, list):
                stack.extend(p)
            elif isinstance(p, dict):
                if (p.get("content-type") or "").lower() == "text/html" \
                        and isinstance(p.get("content"), str):
                    out.append(p["content"])
                elif isinstance(p.get("content"), list):
                    stack.extend(p["content"])
        return "\n".join(out)


    def extract_attachments(part):
        out, stack = [], [part]
        while stack:
            p = stack.pop()
            if isinstance(p, list):
                stack.extend(p)
            elif isinstance(p, dict):
                fname = p.get("filename")
                if fname:
                    out.append(fname)
                elif isinstance(p.get("content"), list):
                    stack.extend(p["content"])
        return out


    if __name__ == "__main__":
        mcp.run(transport="stdio")
  ''
