# WhatsApp archive (whatsapp-archive)

**Date:** 2026-10-28
**Status:** built and deployed to doc2; needs a one-time link (below) before it
archives anything. Android backup import is optional, for full history.
**Host:** `doc2`
**Module:** `modules/nixos/services/whatsapp-archive.nix`
**Code:** `nix/pkgs/whatsapp-archive/` (Go, whatsmeow + pure-Go SQLite)
**Updated:** 2026-10-28, polls (all versions), poll votes, events, album
photos and other wrapped messages, business templates, and `unsupported:`
rows (with raw protobuf) for unknown types; see "Replaying history".
**Revisit:** if WhatsApp changes the linked-device protocol in a way whatsmeow
can't follow, or if the account gets a temporary ban.

## What this is

A personal data connector: every WhatsApp message lands in a SQLite archive on
doc2 within seconds, so agents (and you) can query your chats with SQL. It is
the first test of "own your own connectors" for a personal assistant.

It links to the account as a **companion device** (like WhatsApp Web) using
[whatsmeow](https://github.com/tulir/whatsmeow), and is strictly receive-only:
no sending, no read receipts, no presence. It shows on the phone as a linked
device named `homelab-archive`.

### Why linked device and not the phone backup

Considered 2026-10-28. Android writes a nightly `msgstore.db.crypt15` that can be
decrypted with your own 64-digit E2E backup key. That route never talks to
WhatsApp's servers (no ToS issue, no ban risk), but it is **daily at best**,
which the user ruled out as not fresh enough. So the backup is used only as a
one-time history import. The linked device breaks WhatsApp's ToS; staying
receive-only keeps the ban risk low (bans follow sending/automation).
Google Drive backups were rejected: reading them means impersonating
WhatsApp's OAuth client to Google.

## Layout

| Path | What | Who can read |
|---|---|---|
| `/var/lib/whatsapp-archive/session/session.db` | whatsmeow keys: **can read and send as you** | service user only (0700) |
| `/var/lib/whatsapp-archive/archive.db` | the archive (messages, chats, contacts, FTS index) | `whatsapp-archive` group |
| `/mnt/data/Life/Andy/WhatsApp/media/YYYY/MM/<msg id>.<ext>` | media files | service user + group |
| `/mnt/data/Life/Andy/WhatsApp/archive.db` | daily 03:30 `sqlite .backup` snapshot | same; in the kopia offsite set |

The session keys stay on doc2's local disk on purpose: not NFS, and not
`/mnt/virtio` (doc1 mounts that too). Losing them costs only a re-link; the
archive itself is backed up via the snapshot. The live DB uses a rollback
journal (not WAL) so readers need nothing but read permission.

Archive semantics are append-only, like mailarchive: "delete for everyone"
sets `deleted_at` but keeps the text; edits keep every previous version in
`message_edits`. Status stories and channels are skipped.

## Link (one-time, needs the phone)

On doc2 (as `abl030`, which has the group and passwordless sudo):

```bash
whatsapp-archive-link -phone +614XXXXXXXX   # prints an 8-character code
# phone: Settings -> Linked devices -> Link a device -> "Link with phone number instead"
whatsapp-archive-link                        # alternative: QR code in the terminal
```

The helper stops the service, pairs, keeps receiving the initial history sync
for 2 minutes (`-linger`), then starts the service. The phone keeps pushing
history chunks afterwards; the daemon stores them as they arrive (`source =
'history'`). Media in history older than 30 days is skipped (the CDN has
dropped it); recent media is downloaded.

## Full history from the Android backup (optional)

The linked device only receives what the phone chooses to sync. For
everything:

1. On the phone, turn on end-to-end encrypted backup **with the 64-digit key**
   option (Settings -> Chats -> Chat backup). The password option keeps the
   real key in WhatsApp's HSM, so it can't be decrypted locally. Run a backup.
2. Copy `Android/media/com.whatsapp/WhatsApp/Databases/msgstore.db.crypt15`
   (and optionally `.../WhatsApp/Media/` as `Media/`, and `wa.db.crypt15` for
   contact names) to a dir on doc2 **outside your home**, e.g. `/var/tmp/wa-import`.
3. `whatsapp-archive-import /var/tmp/wa-import <64-char-key>`
4. Delete the directory: `result.json` is your whole history in plaintext.

The import de-duplicates on WhatsApp's message id, so it merges cleanly with
live and history-sync rows and is safe to re-run.

## Querying

```bash
ssh doc2 whatsapp-sql "SELECT count(*) FROM messages"
```

`whatsapp-sql` is `sqlite3 -readonly` on the live DB. Agents on doc1 use the
same command over SSH; there is deliberately no MCP or API (2026-10-28 user
decision: SQL is the interface).

Schema (see `nix/pkgs/whatsapp-archive/db.go`):

- `messages(msg_id, chat_jid, sender_jid, sender_name, from_me, ts, kind, text,
  quoted_id, media_mime, media_file, media_status, source, edited_at, deleted_at)`
  - `ts` is unix seconds; `kind` is text/image/video/video-note/audio/voice/
    document/sticker/location/contact/poll/poll-result/event/album/invite/
    template (business messages)/reply (button/list answers)/placeholder
    (content WhatsApp keeps off linked devices)/reaction/system, or
    `unsupported:<protoField>` for a content type with no handler yet
    (`SELECT kind, count(*) FROM messages WHERE kind LIKE 'unsupported:%' GROUP BY 1`)
  - Album photos arrive as separate messages wrapped in
    `associatedChildMessage`; any `FutureProofMessage` envelope is unwrapped
    generically, so they are stored as ordinary `image`/`video` rows. The
    `album` row is only the header ("N photos, M videos").
  - `raw` holds the protobuf of `unsupported:*` rows only. When a later build
    adds a handler, the daemon upgrades those rows in place on its next start
    (`reprocess: upgraded N of M` in the journal), and a replayed copy of the
    message also upgrades its placeholder. Handled rows are never overwritten.
  - `text` holds the body, or the caption/filename for media
  - `source` is `live`, `history` or `backup`
- `messages_fts` — FTS5 over `text` (`rowid = messages.id`)
- `chats(jid, name, is_group)`, `contacts(jid, name, push_name)`
- `message_edits(msg_id, edited_at, old_text)`, `meta(key, value)`
  (`last_connected`, `logged_out`, `last_backup_import`, `own_jid`)
- Polls: the question and options are a `kind = 'poll'` message. Votes:
  - `poll_options(poll_msg_id, idx, name, hash)`: votes name options by
    SHA-256 of the option text, so options are kept to translate them
  - `poll_votes(poll_msg_id, voter_jid, ts, options, source)`: append-only
    log; `options` is a JSON array of option names (`[]` = vote retracted)
  - `poll_current_votes`: latest vote per voter
  - `poll_results`: per option, the count and the voters' names
  - Live votes are decrypted with the poll's message secret; history-synced
    polls carry their votes already decrypted. The Android backup exporter
    (wtsexporter) does not export polls, so the backup import adds none.

Display names: `chats.name` for groups; for 1:1 chats join `contacts` on
`chat_jid` (`name` is the address-book name, `push_name` their own).

```sql
-- keyword search with chat names
SELECT datetime(m.ts,'unixepoch','localtime') t,
       COALESCE(c.name, ct.name, ct.push_name, m.chat_jid) chat,
       CASE WHEN m.from_me THEN 'me' ELSE COALESCE(m.sender_name, m.sender_jid) END who,
       m.text
FROM messages_fts f JOIN messages m ON m.id = f.rowid
LEFT JOIN chats c ON c.jid = m.chat_jid
LEFT JOIN contacts ct ON ct.jid = m.chat_jid
WHERE messages_fts MATCH 'dinner AND friday' ORDER BY m.ts DESC LIMIT 20;

-- recent conversation with one chat
SELECT datetime(ts,'unixepoch','localtime'), from_me, text FROM messages
WHERE chat_jid = '61400000000@s.whatsapp.net' ORDER BY ts DESC LIMIT 50;

-- is the feed alive?
SELECT * FROM meta;

-- poll results in a chat
SELECT m.text, r.option, r.votes, r.voters
FROM poll_results r JOIN messages m ON m.msg_id = r.poll_msg_id
JOIN chats c ON c.jid = m.chat_jid
WHERE c.name LIKE '%bucks%' ORDER BY m.ts, r.idx;
```

## Replaying history after a handler fix

Since the raw-protobuf change (2026-10-28) a new handler upgrades
`unsupported:*` rows by itself on the next daemon start; no replay needed.

Before that, unknown types were either dropped (first deploy: polls V2/V5/V6,
votes, events, album photos) or stored without raw (the poll-fix build:
`associatedChildMessage`, `albumMessage`, `templateMessage`,
`placeholderMessage`). The phone only sends history once per link, so those
need a replay: on the phone, Settings -> Linked devices -> `homelab-archive`
-> Log out (the daemon exits with LOGGED OUT, which pages), then run
`whatsapp-archive-link` again. Rows are de-duplicated by message id and vote
timestamp; a replayed copy upgrades its `unsupported:*` placeholder.

## Health and alerts

- Kuma monitor **WhatsApp archive** -> `127.0.0.1:9884/health`: 200 only while
  the socket is connected and logged in. It is DOWN before the first link.
- Loki error pattern **WhatsApp archive needs a human** fires on exits that a
  restart can't fix. systemd won't restart on these (`RestartPreventExitStatus`):
  - `LOGGED OUT` (exit 3): unlinked from the phone, or the phone was offline
    for ~14 days. Run `whatsapp-archive-link`.
  - `CLIENT OUTDATED` (exit 4): run `scripts/update_whatsapp_archive.sh` on
    doc1, commit, deploy doc2.
  - `TEMPORARY BAN` (exit 5): leave it stopped until the expiry in the log.
- The service has `ConditionPathExists` on the session DB, so before linking it
  is skipped rather than restart-looping.

## Keeping whatsmeow current

The Go deps float on purpose. `scripts/update_whatsapp_archive.sh` runs as the
`whatsapp-archive` group of the nightly `rolling-flake-update` on doc1: `go get
-u`, `go mod tidy`, `go vet`, then recompute `vendorHash`. The fleet build gates
it and a failure reverts only that group. Its transaction is covered by
`nix/checks/test_rolling_mongodb80_transaction.py`, which runs every case for
both non-flake package groups.

## Not done / next

- No semantic search yet. The mailsearch embed server on igpu could index this
  the same way if keyword search turns out not to be enough.
- Media from a history sync that fails to download stays `expired`/`failed`;
  there is no media-retry request to the phone (it would be a protocol send).
- A Hermes/assistant read path is just `ssh doc2 whatsapp-sql`. Gate it like
  mailsearch (human-present) if it ever reaches an always-on agent.
