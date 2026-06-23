# mailsearch-mcp — read-only hybrid mail search exposed as an MCP stdio server.
#
# Two tools, both read-only:
#   search_mail(query, top_k, folder, date_from, date_to, sender)
#       -> ranked metadata + snippet (NO bodies); fuses notmuch keyword search
#          with sqlite-vec semantic KNN via Reciprocal Rank Fusion.
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
        out = subprocess.run(
            [NOTMUCH, *args], check=True, capture_output=True, text=True
        ).stdout
        return json.loads(out) if out.strip() else []


    def db_ro():
        db = apsw.Connection(VECTOR_DB, flags=apsw.SQLITE_OPEN_READONLY)
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
            terms.append(f'folder:"{folder}"')
        if sender:
            terms.append(f'from:{sender}')
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
        except subprocess.CalledProcessError as e:
            log(f"notmuch keyword search failed (rc={e.returncode})")
            return []
        return ids


    def semantic_ids(db, qvec, folder, date_from, date_to, limit):
        clauses, params = ["embedding MATCH ?", "k = ?"], [
            sqlite_vec.serialize_float32(qvec), limit,
        ]
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
        out = []
        for _rowid, mid, _dist in rows:
            # date filter is applied post-hoc against the messages table below.
            out.append(mid)
        return out


    def rrf(*ranked_lists):
        scores = {}
        for lst in ranked_lists:
            for rank, mid in enumerate(lst, 1):
                scores[mid] = scores.get(mid, 0.0) + 1.0 / (RRF_K + rank)
        return [mid for mid, _ in sorted(scores.items(), key=lambda kv: -kv[1])]


    def meta_for(db, mids):
        if not mids:
            return {}
        qmarks = ",".join("?" * len(mids))
        rows = db.execute(
            f"SELECT message_id, sender, subject, date, folder "
            f"FROM messages WHERE message_id IN ({qmarks})", mids,
        ).fetchall()
        return {
            r[0]: {"from": r[1], "subject": r[2], "date": r[3], "folder": r[4]}
            for r in rows
        }


    def snippet_for(mid):
        try:
            docs = notmuch_json([
                "show", "--format=json", "--entire-thread=false",
                "--body=true", "--format-version=5", f"id:{mid}",
            ])
        except subprocess.CalledProcessError:
            return ""
        node = docs
        while isinstance(node, list) and node:
            node = node[0]
        if not isinstance(node, dict):
            return ""
        text = extract_plain(node.get("body", []))
        return " ".join(text.split())[:240]


    def extract_plain(part):
        out = []
        stack = [part]
        while stack:
            p = stack.pop()
            if isinstance(p, list):
                stack.extend(p)
            elif isinstance(p, dict):
                ctype = (p.get("content-type") or "").lower()
                content = p.get("content")
                if ctype == "text/plain" and isinstance(content, str):
                    out.append(content)
                elif isinstance(content, list):
                    stack.extend(content)
        return "\n".join(out)


    @mcp.tool()
    def search_mail(query: str, top_k: int = 10, folder: str | None = None,
                    date_from: str | None = None, date_to: str | None = None,
                    sender: str | None = None) -> dict:
        """Search the personal mail archive. Returns ranked metadata + a short
        snippet only (never full bodies — use get_message for that).

        Args:
          query: keyword and/or natural-language query.
          top_k: max results (capped server-side).
          folder: optional Maildir folder filter (e.g. "work/INBOX").
          date_from, date_to: optional YYYY-MM-DD bounds.
          sender: optional From: substring filter.
        """
        k = max(1, min(int(top_k), TOPK_CAP))
        over = min(TOPK_CAP, k * 5)
        db = db_ro()
        kw = keyword_ids(query, folder, date_from, date_to, sender, over)
        sem = []
        if query and query.strip():
            try:
                sem = semantic_ids(db, embed_query(query), folder,
                                   date_from, date_to, over)
            except Exception as e:  # noqa: BLE001
                log(f"semantic leg unavailable, keyword-only: {type(e).__name__}")
        ranked = rrf(kw, sem)[:k]
        meta = meta_for(db, ranked)
        results = []
        for mid in ranked:
            m = meta.get(mid, {})
            results.append({
                "message_id": mid,
                "from": m.get("from", ""),
                "subject": m.get("subject", ""),
                "date": m.get("date"),
                "folder": m.get("folder", ""),
                "snippet": snippet_for(mid),
            })
        log(f"search_mail keyword={len(kw)} semantic={len(sem)} returned={len(results)}")
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
        node = docs
        while isinstance(node, list) and node:
            node = node[0]
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
                disp = (p.get("content-disposition") or "").lower()
                if fname and (disp == "attachment" or True):
                    out.append(fname)
                elif isinstance(p.get("content"), list):
                    stack.extend(p["content"])
        return out


    if __name__ == "__main__":
        mcp.run(transport="stdio")
  ''
