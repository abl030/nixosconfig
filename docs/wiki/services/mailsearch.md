# Mail-archive search (notmuch + embeddings + read-only MCP)

**Status: LIVE on doc2** (deployed 2026-06-23, hardening + embed fix 2026-06-24).
Keyword search is fully working over the whole archive (~143k messages). The
semantic (embedding) index is built incrementally; the one-time bootstrap embed
runs for hours on CPU after first deploy. Forgejo #11.

**What it is:** local hybrid search over the mailarchive Maildir on doc2. A
notmuch (Xapian) keyword index and a `nomic-embed` / `sqlite-vec` semantic index
feed two surfaces — a terminal client for human keyword search, and a read-only
MCP tool (`search_mail` + `get_message`) for the Claude agents driven on doc1.
Everything runs locally on doc2; the corpus never leaves the fleet.

Module: `modules/nixos/services/mailsearch.nix`, enabled in
`hosts/doc2/configuration.nix`. Python: `nix/pkgs/mailsearch-{indexer,mcp}.nix`.
Deep probe: `modules/nixos/services/probes/check-mailsearch.nix`.

---

## How to use it

### Human — keyword search (over SSH to doc2)

You (`abl030`) are in the `mailsearch` group on doc2, so the read-only index is
yours to query. Two wrappers are on `PATH` (both point at the shared notmuch
config; you never touch the Maildir):

- **Interactive TUI:** `ssh doc2` then `mailsearch-tui` — `alot`, a full notmuch
  browser (search, thread view, open attachments-by-name). `q` to quit.
- **One-off CLI:** `mailsearch <notmuch-subcommand>`, e.g.
  - `mailsearch search subject:invoice and attachment:pdf`
  - `mailsearch search from:cullenwines.com.au date:2026-01-01..`
  - `mailsearch search barrel repair quote`
  - `mailsearch search 'attachment:"Barrel Repair Quote.pdf"'`   (search by attachment filename)
  - `mailsearch count from:someone@example.com`
  - `mailsearch show id:<message-id>`   (read one message)

notmuch query syntax: `from: to: subject: body: attachment: folder: tag:`,
`date:<from>..<to>` (YYYY-MM-DD, open-ended ok), boolean `and`/`or`/`not`,
quoted phrases, and bare free-text. Full reference:
<https://notmuchmail.org/doc/latest/man7/notmuch-search-terms.html>.

This leg is **keyword/exact-match only** — it does not need the embeddings and
works the moment the deploy lands.

### Agent — hybrid (keyword + semantic) search, from doc1

In a Claude Code session **on doc1**, the `mailsearch` subagent is available.
Just ask in plain language — "search my mail for the barrel repair quote",
"what did the cooper say about the renewal", "find emails from X about Y last
March". It calls:

- `search_mail(query, top_k, folder?, date_from?, date_to?, sender?)` → ranked
  metadata + a short snippet (no bodies), fusing the keyword and semantic legs.
- `get_message(message_id)` → the full body (HTML stripped, length-capped) +
  attachment **filenames** (never payloads) when it needs detail.

**From your phone:** ask Claude — it drives the agent for you. That's the mobile
search surface; there is no web app to maintain.

The **semantic leg** ("find the email about X" with no matching keyword) only
returns hits once a message has been embedded — the bootstrap fills the vector
store over a few hours after first deploy (watch `vectors` count below). Until
then, `search_mail` is effectively keyword-only. Exact strings (invoice numbers,
surnames) always go through the keyword leg, embedded or not.

**Not available to hermes or any always-on/Telegram agent** — by construction
(see Least-privilege below).

---

## Architecture

- **Maildir** (read-only source): `/mnt/data/Life/Andy/Email/{gmail,work}` — a
  `hard` NFS mount from tower. The legacy `Mailstore/` + `export-staging/` trees
  are excluded via notmuch `new.ignore`.
- **Indexes** (local virtiofs, `/mnt/virtio/mailsearch`): the Xapian DB
  (`xapian/`), the sqlite-vec store (`vectors.db`), the GGUF model cache
  (`models/`), and `index.heartbeat` / `embed.heartbeat`. **Never on the NFS
  mount** — Xapian's lock is unreliable over NFS and a hard mount hangs.
- **`mailsearch-index`** (oneshot, timer every 5 min): `notmuch new` (read-only,
  `synchronize_flags=false`) → touch `index.heartbeat` → `mailsearch-indexer`
  embeds the delta. `Nice 15` / idle IO. `restartIfChanged=false` so the
  multi-hour bootstrap never wedges `nixos-rebuild switch` (see Lessons).
- **`mailsearch-embed`** (resident): `llama-server --embeddings --pooling mean
  -c 8192 -b 8192 -ub 8192 -ngl 0` serving `nomic-embed-text-v1.5` (F16 GGUF) on
  **`127.0.0.1:18181`**, CPU only.
- **`mailsearch-mcp`** (SSH forced-command): the read-only MCP server, run as
  `mailsearch-ro` when doc1 connects.
- **`mailsearch-health`** (resident): 200/503 on heartbeat freshness → Kuma.
- **`check-mailsearch`** (deep probe, 30 min): embed endpoint reachable +
  notmuch non-empty + vector store not silently empty/lagging → Kuma. This is
  what caught the embed-500 outage (below) when the shallow heartbeat couldn't.

The embed indexer cleans each message (quote/signature stripping via
`mail-parser-reply`, HTML→text), dedups by Message-ID, prefixes
`search_document:`, embeds, and upserts into sqlite-vec (idempotent
DELETE+INSERT). The MCP embeds the query with `search_query:` and fuses the two
legs with Reciprocal Rank Fusion.

---

## Least-privilege / blast radius

- The index **is** the corpus in searchable form — same secrecy class as the
  mail. Owned `mailsearch-index:mailsearch`, mode `0750`, group-readable only.
- Indexes are **not** in the offsite backup (`kopia-mum`) — rebuildable from the
  Maildir, so a restore re-embeds rather than shipping a second searchable copy.
- The indexer/MCP **never write the Maildir** (`synchronize_flags=false` +
  read-only mount).
- **Query strings are never logged** — indexer + MCP log only counts /
  Message-IDs / timings to stderr (doc2's journal ships to fleet-readable Loki).
- All three systemd units are namespace-sandboxed (`TemporaryFileSystem=/mnt` +
  `BindReadOnlyPaths`/`BindPaths` for only what each needs — #257), loopback-only
  bind, full hardening block.
- **Agent reach is doc1-only.** doc1's MCP wrapper SSHes `mailsearch-ro@doc2`
  over the fleet key; that account's authorized key is a forced command
  (`mailsearch-mcp`, `restrict`, tailnet/LAN `from=`) — it can run nothing but
  the read-only MCP. hermes (Telegram-reachable, prompt-injectable) is excluded
  by key custody. No network listener; the transport is SSH stdio.
- **Known residual:** the MCP runs SSH-spawned (forced command), *not* under
  systemd, so it lacks the namespace/syscall sandbox the indexer has. It is
  read-only by construction under the minimal `mailsearch-ro` user. A full
  sandbox (socket-activated systemd unit reached via `socat`) is a follow-up.

---

## Operations

### Watch the bootstrap / health

```sh
ssh doc2 'mailsearch count "*"'                                        # keyword index size
ssh doc2 'sqlite3 /mnt/virtio/mailsearch/vectors.db "SELECT count(*) FROM messages"'  # vectors embedded
ssh doc2 'journalctl -u mailsearch-index.service -n 20 --no-pager'     # indexer progress / skips
curl -s http://127.0.0.1:18181/health   # (on doc2) embed server ready?
```

The deep probe pages if the embed leg is broken (0 vectors against a real
corpus, or the embed endpoint down). During the one-time bootstrap the vector
count legitimately lags the message count — the lag check is disabled by default
(`MAILSEARCH_MAX_LAG=0`); set it post-bootstrap to catch a steady-state stall.

### Recovery (rebuild from scratch)

Indexes are derived artifacts; the Maildir is never touched.

```sh
ssh doc2 'sudo systemctl stop mailsearch-index.timer'   # (needs the allowlist; else let it idle)
ssh doc2 'rm -rf /mnt/virtio/mailsearch/{xapian,vectors.db}'
# next timer tick rebuilds notmuch + re-embeds (hours)
```

---

## Lessons from the first deploy (2026-06-23 → 24)

Three real bugs surfaced on deploy; all fixed and committed. Recorded so the next
local-inference / NFS-indexing service avoids them:

1. **Port collision.** The embed server's first port (8181) was already bound on
   doc2 → `llama-server` crash-looped on `couldn't bind`. Moved to **18181**.
   *Lesson: pick a distinctive high loopback port and check `ss -tln` first.*
2. **Long oneshot wedges the switch.** `mailsearch-index` is a `Type=oneshot`
   that runs `notmuch new` (scanning 143k files over NFS, ~20 min) then the
   multi-hour embed; `switch-to-configuration` waited on it and the rebuild hung.
   Fixed with `restartIfChanged=false`/`stopIfChanged=false`. The bootstrap scan
   also *saturates the hard NFS mount*, transiently slowing other NFS jobs the
   switch waits on — expected during the one-time bootstrap only.
3. **Embed HTTP 500 on long emails (the "indexer down all night" pager).**
   `llama-server` defaulted the physical batch to 512, so any email >512 tokens
   returned `HTTP 500: input too large to process. increase the physical batch
   size` — the indexer crashed on it and wrote **zero vectors all night**. The
   deep probe correctly paged. Fixed with **`-b 8192 -ub 8192`** (cover a whole
   8192-token email in one pass), `MAX_CHARS=24000` (stay under the ceiling), and
   a per-message fallback in `flush()` so one pathological email skips instead of
   killing the run. A small fraction of very dense/long emails still exceed 8192
   tokens and are skipped (still keyword-searchable).

**Maildir access — no ACL needed.** Contrary to the original plan, the index
user reads the `0700` Maildir over the NFS mount **without** any extra ACL or the
broad `users` group (verified by indexing all ~143k messages). The earlier
"setfacl `g:mailsearch:rX` required" deploy step turned out unnecessary; leave it
out unless a future perms/uid-mapping change breaks reads.

---

## References

- Plan: `docs/plans/2026-06-23-001-feat-mailarchive-search-plan.md`
- Brainstorm: `docs/brainstorms/2026-06-23-mailarchive-search-requirements.md`
- Predecessor (archive bootstrap): `docs/wiki/services/mailarchive.md`
- Templates mirrored: `whisper-server.nix` (llama-server), `mailarchive.nix`
  (oneshot/timer/heartbeat/health), `hermes-operator-deploy.nix` (forced-command).
