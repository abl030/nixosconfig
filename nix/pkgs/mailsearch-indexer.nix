# mailsearch-indexer — embed new mail bodies into a sqlite-vec store.
#
# Runs as a Type=oneshot after the notmuch index refresh (see
# modules/nixos/services/mailsearch.nix). Finds messages present in the notmuch
# Xapian DB but not yet in the vector store, cleans + embeds their bodies via a
# local llama-server (/v1/embeddings, nomic-embed), and upserts vectors keyed by
# Message-ID. Idempotent: the sqlite `messages` table IS the watermark, so a
# re-run with no new mail embeds nothing.
#
# Plan:    docs/plans/2026-06-23-001-feat-mailarchive-search-plan.md (U4)
# Runbook: docs/wiki/services/mailsearch.md
#
# DEPLOY-TIME VERIFY: this is first-cut code validated by `nix flake check`
# (eval only). Runtime behaviour (notmuch JSON field shapes, sqlite-vec apsw
# API, llama-server response shape) must be confirmed on the first doc2 deploy.
{pkgs}: let
  py = pkgs.python3Packages;

  # mail-parser-reply: maintained, pure-Python quote/signature stripper
  # (talon's replacement — talon is abandoned and won't build on modern Python).
  # Not in nixpkgs; packaged here. Sole runtime dep is `regex`.
  mailParserReply = py.buildPythonPackage rec {
    pname = "mail-parser-reply";
    version = "1.36";
    pyproject = true;
    src = pkgs.fetchPypi {
      pname = "mail_parser_reply";
      inherit version;
      hash = "sha256-f0UcWDxsWZvJM1Mab3g/5NGiZEfr1AOCZ4QX27kuEA4=";
    };
    build-system = [py.setuptools];
    propagatedBuildInputs = [py.regex];
    # Pure-Python; upstream has no test extras wired for sandboxed builds.
    doCheck = false;
    pythonImportsCheck = ["mailparser_reply"];
  };
in
  pkgs.writers.writePython3Bin "mailsearch-indexer" {
    libraries = [
      py.apsw
      py.sqlite-vec
      py.html2text
      mailParserReply
    ];
    flakeIgnore = ["E501" "E402"];
  } ''
    """Embed new mail bodies into the sqlite-vec store (idempotent, incremental).

    Environment:
      NOTMUCH_CONFIG          path to the notmuch config (also points at the DB)
      MAILSEARCH_VECTOR_DB    sqlite-vec database file
      MAILSEARCH_EMBED_URL    llama-server OpenAI-compatible endpoint
                              (e.g. http://127.0.0.1:8181/v1/embeddings)
      MAILSEARCH_EMBED_MODEL  model name to send (default "nomic")
      MAILSEARCH_HEARTBEAT    touch this file on a fully-successful run
      MAILSEARCH_BATCH        embeddings per request (default 32)
      MAILSEARCH_DIM          embedding dimension (default 768)
      MAILSEARCH_MAX_CHARS    truncate cleaned body to this many chars (default 30000)
      NOTMUCH_BIN             path to the notmuch binary (default "notmuch")
    """
    import http.client
    import itertools
    import json
    import os
    import subprocess
    import sys
    import time
    import urllib.error
    import urllib.request
    from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

    import apsw
    import html2text
    import sqlite_vec
    from mailparser_reply import EmailReplyParser

    NOTMUCH = os.environ.get("NOTMUCH_BIN", "notmuch")
    VECTOR_DB = os.environ["MAILSEARCH_VECTOR_DB"]
    EMBED_URL = os.environ["MAILSEARCH_EMBED_URL"]
    EMBED_MODEL = os.environ.get("MAILSEARCH_EMBED_MODEL", "nomic")
    HEARTBEAT = os.environ.get("MAILSEARCH_HEARTBEAT")
    BATCH = int(os.environ.get("MAILSEARCH_BATCH", "32"))
    DIM = int(os.environ.get("MAILSEARCH_DIM", "768"))
    MAX_CHARS = int(os.environ.get("MAILSEARCH_MAX_CHARS", "24000"))  # keep under the 8192-token ctx
    # Wedge + throughput guards (2026-06-25). A single pathological message hung a
    # whole run: html2text / the reply-parser regex can spin on degenerate or huge
    # bodies, and notmuch can hang on a stale NFS handle. MAX_RAW bounds the raw
    # bytes fed to the CPU-heavy parsers (NOT what we embed — the cleaned text is
    # still cut to MAX_CHARS, so a real email loses nothing; only multi-hundred-KB
    # degenerate bodies are clipped before parsing) and NOTMUCH_TIMEOUT bounds the
    # subprocess. Together they make every per-message op finite, so no message can
    # hang the run — a worker returns an error string and that one message is skipped.
    # WORKERS: fetch+clean is I/O-bound (notmuch show over NFS releases the GIL on
    # the subprocess wait), so a thread pool overlaps that latency and keeps the
    # serial embedder continuously fed instead of stalling one message at a time —
    # the embed server was idle ~most of the time waiting on single-threaded fetch.
    MAX_RAW = int(os.environ.get("MAILSEARCH_MAX_RAW", "300000"))
    NOTMUCH_TIMEOUT = int(os.environ.get("MAILSEARCH_NOTMUCH_TIMEOUT", "120"))
    WORKERS = int(os.environ.get("MAILSEARCH_FETCH_WORKERS", "8"))


    # NEVER log message bodies or search queries — doc2 ships the journal to Loki,
    # which the agent fleet can read. Only counts / Message-IDs / timings.
    def log(msg):
        sys.stderr.write(f"mailsearch-indexer: {msg}\n")
        sys.stderr.flush()


    def notmuch_json(args):
        # notmuch can emit non-UTF-8 bytes from malformed message headers; decode
        # tolerantly (errors=replace) so one bad message can't crash the run.
        out = subprocess.run(
            [NOTMUCH, *args], check=True, capture_output=True, timeout=NOTMUCH_TIMEOUT
        ).stdout
        text = out.decode("utf-8", errors="replace")
        return json.loads(text) if text.strip() else []


    def all_message_ids():
        # Flat JSON array of message-id strings (no "id:" prefix).
        return notmuch_json(["search", "--output=messages", "--format=json", "*"])


    def walk_parts(part, out):
        """Collect (text/plain, html, attachment-filenames) from a notmuch part tree."""
        if isinstance(part, list):
            for p in part:
                walk_parts(p, out)
            return
        if not isinstance(part, dict):
            return
        disp = (part.get("content-disposition") or "").lower()
        ctype = (part.get("content-type") or "").lower()
        fname = part.get("filename")
        if disp == "attachment" or fname:
            if fname:
                out["attachments"].append(fname)
            return  # never read attachment payloads
        content = part.get("content")
        if ctype == "text/plain" and isinstance(content, str):
            out["plain"].append(content)
        elif ctype == "text/html" and isinstance(content, str):
            out["html"].append(content)
        elif isinstance(content, list):
            walk_parts(content, out)


    def find_message(docs):
        # notmuch show returns a forest of [msg, [replies]] pairs; with
        # --entire-thread=false the non-matched messages are empty {} stubs.
        # Descend and return the first NON-empty message dict (the matched one) —
        # blindly taking node[0] lands on the empty thread-root stub for replies.
        if isinstance(docs, list):
            for item in docs:
                found = find_message(item)
                if found is not None:
                    return found
            return None
        if isinstance(docs, dict):
            return docs if (docs.get("id") or docs.get("headers")) else None
        return None


    def fetch_message(mid):
        try:
            docs = notmuch_json([
                "show", "--format=json", "--entire-thread=false",
                "--include-html", "--format-version=5", f"id:{mid}",
            ])
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
                json.JSONDecodeError, ValueError):
            return None
        node = find_message(docs)
        if not isinstance(node, dict):
            return None
        headers = node.get("headers", {}) or {}
        out = {"plain": [], "html": [], "attachments": []}
        walk_parts(node.get("body", []), out)
        if out["plain"]:
            body = "\n".join(out["plain"])
        elif out["html"]:
            h = html2text.HTML2Text()
            h.ignore_links = True
            h.ignore_images = True
            body = "\n".join(h.handle(x[:MAX_RAW]) for x in out["html"])
        else:
            body = ""
        path = node.get("filename")
        if isinstance(path, list):
            path = path[0] if path else None
        return {
            "message_id": mid,
            "subject": headers.get("Subject", ""),
            "sender": headers.get("From", ""),
            "date": int(node.get("timestamp", 0) or 0),
            "body": body,
            "attachments": out["attachments"],
            "path": path or "",
        }


    def folder_account(path):
        """Derive (account, folder) from the Maildir path .../Email/<account>/<folder>/cur/..."""
        account, folder = "", ""
        marker = "/Email/"
        i = path.find(marker)
        if i >= 0:
            rest = path[i + len(marker):]
            parts = rest.split("/")
            if parts:
                account = parts[0]
            # strip the trailing cur|new|tmp + filename
            fparts = [p for p in parts[1:-2] if p] if len(parts) > 2 else []
            folder = "/".join([account] + fparts) if fparts else account
        return account, folder


    def clean_body(rec):
        parser = EmailReplyParser(languages=["en"])
        body = parser.parse_reply(text=(rec["body"] or "")[:MAX_RAW])
        # Fold attachment filenames into the embedded text so semantic search can
        # surface "Barrel Repair Quote.pdf" by name (R2 — filenames only).
        if rec["attachments"]:
            body = body + "\nAttachments: " + ", ".join(rec["attachments"])
        text = (rec["subject"] + "\n" + body).strip()
        return text[:MAX_CHARS]


    def embed(texts):
        payload = json.dumps({
            "model": EMBED_MODEL,
            "input": ["search_document: " + t for t in texts],
        }).encode()
        req = urllib.request.Request(
            EMBED_URL, data=payload,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=600) as r:
            data = json.loads(r.read())
        rows = sorted(data["data"], key=lambda d: d["index"])
        return [row["embedding"] for row in rows]


    def embed_one(text):
        """Embed a single document, shrinking on context-overflow.

        llama-server rejects inputs over its batch/ctx (8192 tokens) with an
        HTTP 500 'input (N tokens) is too large to process'. MAX_CHARS can't
        guarantee a token bound — the token/char ratio swings with content, so
        token-dense bodies (big auto-generated HTML tables, base64, CJK) blow
        the ctx even after the char cap. Those used to error, get skipped, and
        — because the `messages` table is the only watermark — be retried EVERY
        run forever (~4.8k messages churning the embed server + log). On that
        specific error we halve the text and retry down to a floor, so the
        message embeds instead of being dropped. Only the tail is lost; the
        message lead is what semantic search needs.

        Connection drops (RemoteDisconnected / reset / timeout) get a bounded
        backoff-retry: the embed server has ONE slot, so a burst — e.g. the
        one-time backlog recovery firing thousands of requests across the
        worker pool — saturates its accept queue and it drops connections
        instead of 500ing. Those are transient, so retry the same input a few
        times (the backoff also lets the queue drain) before giving up → then
        skip + retry next run, as before.
        """
        t = text
        conn_tries = 0
        while True:
            try:
                return embed([t])[0]
            except urllib.error.HTTPError as e:
                detail = ""
                try:
                    detail = e.read().decode("utf-8", "replace")
                except Exception:  # noqa: BLE001
                    pass
                if "too large" in detail and len(t) > 2000:
                    t = t[: len(t) // 2]
                    continue
                raise
            except (http.client.HTTPException, OSError):
                # RemoteDisconnected, ConnectionResetError, socket timeout, …
                # HTTPError subclasses OSError but is handled above, so it never
                # reaches here. Bounded so a real outage still gives up + skips.
                conn_tries += 1
                if conn_tries > 6:
                    raise
                time.sleep(min(2 ** conn_tries, 20))


    def open_db():
        db = apsw.Connection(VECTOR_DB)
        # No WAL: the read-only MCP runs as a different user with only group-read
        # and cannot create the -shm/-wal sidecars. Default rollback journal +
        # a busy timeout lets the single writer and the RO reader coexist.
        db.setbusytimeout(5000)
        db.enableloadextension(True)
        db.loadextension(sqlite_vec.loadable_path())
        db.enableloadextension(False)
        db.execute("""
            CREATE TABLE IF NOT EXISTS messages(
              rowid INTEGER PRIMARY KEY,
              message_id TEXT UNIQUE NOT NULL,
              account TEXT, folder TEXT, date INTEGER,
              sender TEXT, subject TEXT, has_attachments INTEGER, path TEXT
            )""")
        db.execute(f"""
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_messages USING vec0(
              message_rowid INTEGER PRIMARY KEY,
              embedding FLOAT[{DIM}] distance_metric=cosine,
              account TEXT partition key,
              folder TEXT,
              date INTEGER
            )""")
        return db


    def existing_ids(db):
        return {row[0] for row in db.execute("SELECT message_id FROM messages")}


    def upsert(db, rec, vec):
        cur = db.execute(
            "SELECT rowid FROM messages WHERE message_id = ?", (rec["message_id"],)
        ).fetchall()
        if cur:
            rowid = cur[0][0]
        else:
            db.execute(
                "INSERT INTO messages(message_id, account, folder, date, sender, "
                "subject, has_attachments, path) VALUES(?,?,?,?,?,?,?,?)",
                (rec["message_id"], rec["account"], rec["folder"], rec["date"],
                 rec["sender"], rec["subject"], 1 if rec["attachments"] else 0,
                 rec["path"]),
            )
            rowid = db.last_insert_rowid()
        # sqlite-vec 0.1.6 has no UPSERT — DELETE then INSERT by rowid.
        db.execute("DELETE FROM vec_messages WHERE message_rowid = ?", (rowid,))
        db.execute(
            "INSERT INTO vec_messages(message_rowid, embedding, account, folder, date) "
            "VALUES(?,?,?,?,?)",
            (rowid, sqlite_vec.serialize_float32(vec),
             rec["account"], rec["folder"], rec["date"]),
        )


    def fetch_clean_embed(mid):
        # Worker (pool thread): fetch + clean + EMBED one message →
        # (mid, rec|None, vec|None, err|None). The embed runs HERE so up to WORKERS
        # requests are in flight at once and the embed server's slots stay saturated
        # — a serial embed leaves a GPU ~40-50% idle. embed() releases the GIL on the
        # HTTP wait; bounded by MAX_RAW + NOTMUCH_TIMEOUT. No DB here (main writes).
        try:
            rec = fetch_message(mid)
            if rec is None:
                return (mid, None, None, None)
            rec["account"], rec["folder"] = folder_account(rec["path"])
            rec["clean"] = clean_body(rec)
            if not rec["clean"]:
                return (mid, None, None, None)
            vec = embed_one(rec["clean"])
            return (mid, rec, vec, None)
        except Exception as e:  # noqa: BLE001
            return (mid, None, None, type(e).__name__)


    def main():
        t0 = time.time()
        db = open_db()
        have = existing_ids(db)
        ids = all_message_ids()
        todo = [m for m in ids if m not in have]
        log(f"notmuch messages={len(ids)} already-embedded={len(have)} new={len(todo)} workers={WORKERS}")
        done = 0
        skipped = 0
        pairs = []
        # Each worker fetches + cleans + EMBEDS one message, so up to WORKERS embeds
        # are in flight at once (keeps the embed server's slots full); the main thread
        # only writes the DB (single writer, no locking). The sliding window bounds
        # memory and keeps the pool fed regardless of backlog size.
        pending = iter(todo)
        with ThreadPoolExecutor(max_workers=WORKERS) as ex:
            inflight = {
                ex.submit(fetch_clean_embed, m)
                for m in itertools.islice(pending, WORKERS * 4)
            }
            while inflight:
                ready, inflight = wait(inflight, return_when=FIRST_COMPLETED)
                for fut in ready:
                    mid, rec, vec, err = fut.result()
                    nxt = next(pending, None)
                    if nxt is not None:
                        inflight.add(ex.submit(fetch_clean_embed, nxt))
                    if err is not None:
                        skipped += 1
                        log(f"skip {mid[:50]} (fetch/embed error: {err})")
                        continue
                    if rec is None:
                        continue
                    pairs.append((rec, vec))
                    if len(pairs) >= BATCH:
                        done += commit_vectors(db, pairs)
                        pairs = []
        if pairs:
            done += commit_vectors(db, pairs)
        log(f"embedded={done} skipped={skipped} elapsed={int(time.time() - t0)}s")
        # Reached only on success — an embed/db failure raises and skips this,
        # so the heartbeat reflects the last fully-successful run.
        if HEARTBEAT:
            with open(HEARTBEAT, "w") as fh:
                fh.write(str(int(time.time())))


    def commit_vectors(db, pairs):
        # Embedding already happened in the workers; just persist. Single writer
        # (main thread only), so a plain transaction with no locking.
        if not pairs:
            return 0
        with db:  # transaction
            for rec, vec in pairs:
                upsert(db, rec, vec)
        # Touch the heartbeat per batch so a multi-hour bootstrap run stays
        # "live" to the health monitor instead of going stale for hours.
        if HEARTBEAT:
            with open(HEARTBEAT, "w") as fh:
                fh.write(str(int(time.time())))
        return len(pairs)


    if __name__ == "__main__":
        main()
  ''
