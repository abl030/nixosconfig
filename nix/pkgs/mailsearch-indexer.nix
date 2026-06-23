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
    import json
    import os
    import subprocess
    import sys
    import time
    import urllib.request

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


    # NEVER log message bodies or search queries — doc2 ships the journal to Loki,
    # which the agent fleet can read. Only counts / Message-IDs / timings.
    def log(msg):
        sys.stderr.write(f"mailsearch-indexer: {msg}\n")
        sys.stderr.flush()


    def notmuch_json(args):
        out = subprocess.run(
            [NOTMUCH, *args], check=True, capture_output=True, text=True
        ).stdout
        return json.loads(out) if out.strip() else []


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
        except subprocess.CalledProcessError:
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
            body = "\n".join(h.handle(x) for x in out["html"])
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
        body = parser.parse_reply(text=rec["body"] or "")
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


    def main():
        t0 = time.time()
        db = open_db()
        have = existing_ids(db)
        ids = all_message_ids()
        todo = [m for m in ids if m not in have]
        log(f"notmuch messages={len(ids)} already-embedded={len(have)} new={len(todo)}")
        done = 0
        batch = []
        for mid in todo:
            rec = fetch_message(mid)
            if rec is None:
                continue
            rec["account"], rec["folder"] = folder_account(rec["path"])
            rec["clean"] = clean_body(rec)
            if not rec["clean"]:
                continue
            batch.append(rec)
            if len(batch) >= BATCH:
                done += flush(db, batch)
                batch = []
        if batch:
            done += flush(db, batch)
        log(f"embedded={done} elapsed={int(time.time() - t0)}s")
        # Reached only on success — an embed/db failure raises and skips this,
        # so the heartbeat reflects the last fully-successful run.
        if HEARTBEAT:
            with open(HEARTBEAT, "w") as fh:
                fh.write(str(int(time.time())))


    def flush(db, batch):
        try:
            pairs = list(zip(batch, embed([r["clean"] for r in batch])))
        except Exception as e:  # noqa: BLE001
            # One pathological message (e.g. over the model context) would 500
            # the whole batch and previously crashed the entire run. Fall back
            # to per-message; skip the individual messages that still fail.
            log(f"batch embed failed ({type(e).__name__}); retrying per-message")
            pairs = []
            for rec in batch:
                try:
                    pairs.append((rec, embed([rec["clean"]])[0]))
                except Exception as e2:  # noqa: BLE001
                    log(f"skip {rec['message_id'][:50]} (embed failed: {type(e2).__name__})")
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
