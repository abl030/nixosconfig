# Mail-archive search (notmuch + embeddings + read-only MCP)

**Status: LIVE on doc2** (deployed 2026-06-23, hardening + embed fix 2026-06-24).
Keyword search is fully working over the whole archive (~143k messages). The
semantic (embedding) index bootstrap **completed 2026-07-01** — the vector store
now covers the full archive (bar a handful of pathological dense emails), so
semantic search + `find_similar` reach old mail too. **`mode=` selector +
`find_similar` ("more like this") added 2026-07-01.** Forgejo #11.

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
yours to query. Three wrappers are on `PATH` (all point at the shared notmuch
config; you never touch the Maildir):

- **Live filter (recommended):** `ssh doc2` then `mailsearch-live` — an `fzf`
  "search as you type" box. Every keystroke re-runs `notmuch search` (sub-second
  over Xapian) and replaces the list; words **AND** together so the set narrows
  as you type. Optionally seed it: `mailsearch-live from:cullenwines.com.au`.
  Keys: type a notmuch query (`from:`, `subject:`, `attachment:`, `date:a..b`,
  bare words) → list filters live; **↑/↓** move; right pane previews the focused
  email (HTML rendered via w3m); **Enter** opens it in the full alot reader and
  returns here on quit; **Alt-Enter** freezes the current results and switches to
  fzf's own fuzzy match to narrow *that subset*; **Ctrl-/** toggles the preview;
  **Esc** quits. This is the free-typing surface — use it first.
- **alot browser:** `ssh doc2` then `mailsearch-tui` — `alot`, a command-driven
  notmuch browser (thread view, attachments-by-name). It is **not** type-to-filter:
  it opens on an empty buffer (this index has no `tag:inbox`), so press `o` (or
  `\`) to open the search prompt and type a query, `Enter` to open a thread, `|`
  to refine/narrow the current results, `Tab` to switch result buffers, `?` for
  keybindings, `q` to quit. You can also launch straight into results:
  `mailsearch-tui search subject:invoice and attachment:pdf`.
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

- `search_mail(query, top_k, mode?, folder?, date_from?, date_to?, sender?)` →
  ranked metadata + a short snippet (no bodies). **`mode` (added 2026-07-01)
  selects the retrieval strategy and defaults to `"keyword"`** — semantic is
  now **opt-in**, not silently fused into every call:
    - `"keyword"` (default) — notmuch only; exact/structured; works even with the
      embed server down.
    - `"semantic"` — sqlite-vec KNN only; fuzzy "about X" recall (pass prose).
    - `"hybrid"` — both legs fused with Reciprocal Rank Fusion (the pre-2026-07-01
      always-on behaviour; now chosen explicitly).
- `find_similar(message_id, top_k, folder?, date_from?, date_to?)` → **"more like
  this"** (added 2026-07-01): messages semantically nearest to an existing one via
  its *stored* vector — no re-embed, no query text. Reads the seed's vector back
  out of vec0 and probes the KNN with it; returns `{"error": ...}` if the seed
  isn't embedded yet. This is the "anchor by keyword, then pull the semantic
  cluster" move that makes the vector store earn its keep.
- `get_message(message_id)` → the full body (HTML stripped, length-capped) +
  attachment **filenames** (never payloads) when it needs detail.

**Why opt-in (2026-07-01):** RRF-fusing the semantic leg into *every* query added
newsletter noise to well-specified keyword searches for no gain — and the one
thing embeddings uniquely offer (nearest-neighbour from an example) wasn't exposed
at all, since `query` is a notmuch string with no way to seed from a document.
`mode=` + `find_similar` fix both: keyword stays the clean default, and semantic
becomes a tool the agent reaches for deliberately. Tone/sentiment queries are **not**
a retrieval job — embeddings are topic-dominated; that stays an LLM-read task.

**From your phone:** ask Claude — it drives the agent for you. That's the mobile
search surface; there is no web app to maintain.

The **semantic leg** ("find the email about X" with no matching keyword, or any
`find_similar` call) needs a message embedded to return it — and as of the
**bootstrap completing 2026-07-01** the vector store covers the full ~143k archive
(bar a handful of pathological dense emails), so semantic/`find_similar` now reach
old mail too. Exact strings (invoice numbers, surnames) always go through the
keyword leg, embedded or not.

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

## Lessons from the first deploy (2026-06-23 → 25)

Four bugs surfaced (three on the first deploy, one on 2026-06-25); all fixed and
committed. Recorded so the next local-inference / NFS-indexing service avoids them:

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
   tokens and were skipped (still keyword-searchable) — **superseded 2026-06-28:
   they're now shrink-and-retried instead of skipped, see the 2026-06-28 section
   below.**
4. **Embed context silently capped at 2048 — index stalled at ~35% (2026-06-25).**
   Despite the recommended `-c 8192 --rope-scaling yarn --rope-freq-scale 0.75`,
   the `already-embedded` watermark climbed to ~49.5k/143k then flatlined (**+6
   over 6h**), with `llama-server` rejecting every longer email: `input (N tokens)
   is larger than the max context size (2048 tokens). skipping`. RoPE scaling *was*
   working (`n_ctx_seq=8192`) — but **two** independent llama-server quirks each
   capped the usable per-slot context back to 2048, so any email over ~2048 tokens
   was skipped (no error to the indexer, just a silent `skip`):
     1. **Slot division.** Banner: `n_parallel is set to auto, using n_parallel = 4`
        → llama-server divides `n_ctx` across slots, `8192/4 = 2048` per slot.
        Pinning `--parallel 1` gives the single slot the full 8192.
     2. **Trained-context cap.** Even with one slot, the banner then showed
        `the slot context (8192) exceeds the training context of the model (2048)
        - capping` → `new slot, n_ctx = 2048`. llama-server caps each slot to the
        GGUF `n_ctx_train` and **ignores rope/YaRN** — upstream bug
        [ggml-org/llama.cpp#22140](https://github.com/ggml-org/llama.cpp/issues/22140)
        (also [#17459](https://github.com/ggml-org/llama.cpp/issues/17459)). Lift it
        with `--override-kv nomic-bert.context_length=int:8192` (raises the value
        `n_ctx_train` reads) plus `--yarn-orig-ctx 2048` (keeps YaRN scaling
        anchored to the real 2048 training context).
   **Full fix (all three):** `--parallel 1 --override-kv
   nomic-bert.context_length=int:8192 --yarn-orig-ctx 2048` (atop the existing
   `-c 8192 -b 8192 -ub 8192 --rope-scaling yarn --rope-freq-scale 0.75`). Verified
   on doc1 (llama-cpp 9608): slot loads at `n_ctx = 8192`, a 16k-char (~4k-token)
   email returns a 768-dim vector with HTTP 200. *No truncation needed.* *Lesson:
   for an embedding server check the load banner for BOTH the slot-division and the
   trained-context cap — both are silent and either one strands long inputs.*
5. **One pathological email wedged the whole run (2026-06-25).** After the embed
   fix, the bootstrap *still* stalled at ~49.6k: the indexer process sat in state
   `R` (pure CPU, no embed call, no NFS/notmuch child) — spinning inside the
   per-message clean step (`html2text` / the reply-parser regex) on a single
   degenerate body, with **no per-message timeout**. Because `notmuch_json`'s
   `subprocess.run` and `clean_body` had no bound, one bad message hung the run
   indefinitely, and it would re-hit the *same* message every run → permanent
   stall. Fixed in `nix/pkgs/mailsearch-indexer.nix` by making every per-message
   op **finite**: `MAX_RAW` (300 KB) caps the raw bytes fed to the parsers (does
   **not** affect embedded content — still cut to `MAX_CHARS`) and `NOTMUCH_TIMEOUT`
   (120 s) bounds the subprocess, so a bad message just gets `skipped=` (in the
   summary log), never hangs the run. *(An earlier cut used a `SIGALRM` backstop;
   it was dropped once fetch+clean moved into worker threads — SIGALRM only fires
   on the main thread — and the size cap + subprocess timeout already bound every
   op.)* *Lesson: any per-message CPU/IO step in a long batch job needs a hard
   per-item bound — a size cap for C-extension regex, `timeout=` on subprocess.*
   **Recovery:** a wedged run can't be cleared by a deploy (`restartIfChanged=false`),
   so doc2 has a scoped NOPASSWD `systemctl restart --no-block mailsearch-index.service`
   (`hosts/doc2/configuration.nix`) for the bastion to relaunch it.
6. **Backfill was fetch-bound, not embed-bound (2026-06-25).** Once unwedged, the
   bootstrap crawled at ~720 emails/hr with the embed server **idle most of the
   time** (`all slots are idle` between bursts) and doc2 at load ~12 — the
   bottleneck was the single-threaded `notmuch show` per message over the hard NFS
   mount, not embedding. Fixed by running `fetch_and_clean` across a
   `ThreadPoolExecutor` (`MAILSEARCH_FETCH_WORKERS`, default 8): `notmuch show`
   releases the GIL on the subprocess wait, so the workers overlap NFS latency and
   keep the (still serial, single-writer) embed + DB loop continuously fed. A
   sliding window of ~`WORKERS*8` in-flight messages bounds memory regardless of
   backlog size. *Lesson: profile WHERE a slow batch job waits before scaling the
   wrong stage — the idle embed server said "fetch-bound" out loud.*

**Maildir access — no ACL needed.** Contrary to the original plan, the index
user reads the `0700` Maildir over the NFS mount **without** any extra ACL or the
broad `users` group (verified by indexing all ~143k messages). The earlier
"setfacl `g:mailsearch:rX` required" deploy step turned out unnecessary; leave it
out unless a future perms/uid-mapping change breaks reads.

---

## 2026-06-28 — phantom write-path alert + recovering the long-email tail

Two more issues, both found via morning triage and fixed the same day.

### A. "Mailsearch index write-path DOWN" paged every ~30 min — and had NEVER worked

The Kuma push monitor for the deep write-path probe had been **DOWN since the
probe landed (0 successful pushes in 7 days)**, paging ~every 30 min. Not
mailsearch — a **permissions** bug:

- The deep-probe is the *only* probe that drops privilege (`User = indexUser`,
  for least-privilege mail access); every sibling probe runs as root.
- Its push-URL is `/var/lib/homelab/monitoring/push-urls/<slug>.url`. That dir
  was made `0755` *specifically* so non-root probes could read it — but the
  **parent** `/var/lib/homelab/monitoring` was `0750 root root`, so a non-root
  user had no traverse bit and couldn't descend to the file. The runner's
  `[ -r "$url_file" ]` failed `EACCES` → logged the misleading **"push URL file
  missing … waiting for monitoring-sync"** (it wasn't missing; sync *had* written
  it) → never pushed → Kuma's no-heartbeat window flipped it DOWN.
- **Fix:** tmpfiles `/var/lib/homelab/monitoring` `0750 → 0751` (traverse-only;
  `monitoring_sync.nix`, commit `a23c1976`). Honors the existing "push URLs are
  non-secret" model (the dir was already `0755`). For zero token exposure later:
  per-probe-user ACL or `LoadCredential` (noted in-module). **General lesson: a
  non-root systemd unit reading a file under a `0750 root` dir fails on parent
  *traversal*, not the file's own mode — the error reads like ENOENT.**

### B. The dense/long-email tail — recovered, not skipped (supersedes lesson #3)

~4,831 messages (3.4% — old auto-generated O365 scheduler/JavaMail mail with big
HTML tables) cleaned to bodies of **8208–15252 tokens**, over llama-server's 8192
batch/ctx → HTTP 500 `input (N tokens) is too large`. Because **the `messages`
table is the only watermark, a skipped message is retried every run forever** — a
~3.6k-message burst hammering the embed server + Loki each cycle, and 3.4% of the
archive permanently missing from semantic search.

`MAX_CHARS` can't bound *tokens* (token/char ratio swings with content), so the
fix is in the indexer (`nix/pkgs/mailsearch-indexer.nix`):

- **`embed_one()`** halves the text and retries on the "too large" `HTTPError`
  down to a 2000-char floor → the message embeds (tail lost; the lead is what
  semantic search needs) instead of being dropped+churned (commit `0ec8e55f`).
- **Connection-drop backoff** — the embed server is **single-slot**, so the
  one-time recovery firing 4.8k requests × 8 workers saturated its accept queue
  and it dropped connections (`RemoteDisconnected`) instead of cleanly 500ing.
  `embed_one()` now also catches `http.client.HTTPException`/`OSError` and retries
  with bounded backoff (commit `28c3d7a1`). *nvtop on igpu was normal throughout
  — it was queue saturation, not a GPU/crash issue.*
- **One-time recovery** of the existing backlog: run the indexer with a temporary
  `MAILSEARCH_MAX_CHARS=8000` (no input overflows → no rejects → no storm →
  full-speed clean) via a non-persistent `/run` drop-in; it's GPU-bound on the
  iGPU (~hours for 4.8k long messages). Steady state stays `MAX_CHARS=24000` (full
  English emails) + the `embed_one` shrink-retry as the backstop for the rare
  overflow. The `/run` drop-in self-clears on doc2's nightly reboot.

*General lesson: an embedding model's context is a hard ceiling — cap by a
mechanism that actually bounds tokens (shrink-and-retry on the server's own
"too large", or a token-aware cap), not a fixed char count; and a 1-slot
inference server needs client-side backoff under burst, not just more workers.*

---

## References

- Plan: `docs/plans/2026-06-23-001-feat-mailarchive-search-plan.md`
- Brainstorm: `docs/brainstorms/2026-06-23-mailarchive-search-requirements.md`
- Predecessor (archive bootstrap): `docs/wiki/services/mailarchive.md`
- Templates mirrored: `whisper-server.nix` (llama-server), `mailarchive.nix`
  (oneshot/timer/heartbeat/health), `hermes-operator-deploy.nix` (forced-command).
