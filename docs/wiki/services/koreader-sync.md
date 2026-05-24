# KOReader ↔ Komga progress sync

**Date written:** 2026-05-24
**Status:** ✅ working end-to-end as of 2026-05-24
**Server module:** `modules/nixos/services/komga.nix`
**Client setup script:** none — file-edit + REST recipe below
**Sync server:** Komga's built-in `/koreader` endpoint at https://magazines.ablz.au

## What this is

KOReader's kosync plugin pushes read position to a sync server on every page
turn / document close, and pulls it on document open. Komga implements the
kosync wire protocol natively at `/koreader/*`, so the same Komga that serves
the OPDS catalog is also the sync backend — no separate `kosync-py`/
`kosyncsrv`.

End result: read 40 % of a magazine on the phone, open it on a Boox, KOReader
silently jumps to page N. No taps, no manual "Sync now".

## The four landmines

Bringing this up from zero hit four non-obvious failure modes in sequence.
Future-you needs to know each one or you'll re-debug the same wall:

### 1. Komga needs `hashKoreader=true` per library

Komga stores two hashes for every book: `fileHash` (full-file MD5, always on
when `hashFiles=true`) and `fileHashKoreader` (partial-MD5 over the file
head/tail, KOReader's specific algorithm). KOReader's sync calls reference
the **partial** hash; full-file MD5 is the wrong key.

`hashKoreader` is **off by default** on new libraries. With it off,
`fileHashKoreader` is null on every book, and every kosync `PUT` returns
`404 Book not found`. Auth is fine, endpoint is fine, the lookup just can't
match.

**Automated:** `scripts/komga-sync.py` ensures this on every daily run (see
`ensure_hashkoreader()` — flips any library where it's false and triggers an
analyze). New libraries are picked up within 24 h. To force immediately on a
brand-new library:

```bash
ssh doc2 sudo systemctl start komga-sync
```

Or by hand:

```bash
KEY="$(sops -d secrets/hosts/doc2/komga-sync.env | grep KOMGA_API_KEY | cut -d= -f2-)"
curl -sS -H "X-API-Key: $KEY" -X PATCH -H 'Content-Type: application/json' \
  -d '{"hashKoreader":true}' \
  https://magazines.ablz.au/api/v1/libraries/<LIBRARY_ID>
curl -sS -H "X-API-Key: $KEY" -X POST \
  https://magazines.ablz.au/api/v1/libraries/<LIBRARY_ID>/analyze
```

Analyze hashes every book at ~200 ms each — a few minutes for a couple of
hundred files.

### 2. KOReader settings live in the nested `["kosync"]` table, not top-level

KOReader migrated kosync settings from flat top-level `kosync_username` /
`kosync_userkey` / `kosync_custom_server` keys into a nested
`["kosync"] = { username = …, userkey = …, custom_server = …, … }` table in
**July 2023** (commit in `frontend/ui/data/onetime_migration.lua`).

Top-level `kosync_*` keys still parse without error but are **completely
ignored** by the plugin. Writing them is silent failure.

### 3. Komga ignores `X-Auth-Key` — only reads `X-Auth-User`

Standard kosync uses two headers: `X-Auth-User` (username) and `X-Auth-Key`
(MD5 of password). Komga's implementation (`SecurityConfiguration.kt`)
reads only `X-Auth-User`, and expects its value to be the **raw Komga API
key** — not the email, not the userId, not any MD5.

KOReader's plugin sends `settings.username` as `X-Auth-User` and
`settings.userkey` as `X-Auth-Key`. So:

- `kosync.username` **must** be the API key (this is what Komga sees).
- `kosync.userkey` must be non-empty (the plugin gates "is registered?" on
  this), but its value is irrelevant on the wire — set it to the same API
  key for simplicity.

### 4. KOReader is a cached Android process — file edits get steamrolled

Even when KOReader is closed and `pgrep koreader` returns nothing, Android
keeps the app as a cached process holding the parsed settings in memory.
When something nudges it (system memory pressure, Android lifecycle event),
it serialises memory back to `settings.reader.lua` and clobbers any edits
you made meanwhile.

**Before editing settings:** Settings → Apps → KOReader → **Force stop**.
Termux's `am force-stop` is hijacked; the system `am` requires
`FORCE_STOP_PACKAGES` permission you don't have without root.

## End-to-end headless setup for a new device

Prereqs: SSH access to the phone/tablet via Termux (`ssh phone`,
`termux-setup-storage` already granted), KOReader installed, on version
**2026.03 or newer** (older versions silently drop progress pulls from
Komga — see [koreader#14596](https://github.com/koreader/koreader/issues/14596)).

### 1. Mint a Komga API key for this device

```bash
curl -sS -u 'YOUR_EMAIL:YOUR_PASSWORD' \
  -X POST 'https://magazines.ablz.au/api/v2/users/me/api-keys' \
  -H 'Content-Type: application/json' \
  -d '{"comment":"koreader-<device-name>"}'
```

Response includes `"key": "<api-key>"` — grab it. Listing keys only ever
shows `******`; creating is the only path to the plaintext.

### 2. Force-stop KOReader on the device

Settings → Apps → KOReader → Force stop. Verify with
`ssh <device> "pgrep -af koreader | grep -v pgrep"` — should print nothing.

### 3. Edit `settings.reader.lua` and `opds.lua`

```bash
ssh <device> "awk '
  /^    \[\"kosync\"\] = \{/ { in_kosync=1; print; next }
  in_kosync && /^    \},/ {
    print \"        [\\\"auto_sync\\\"] = true,\"
    print \"        [\\\"checksum_method\\\"] = 0,\"          # 0=binary
    print \"        [\\\"sync_forward\\\"] = 2,\"             # 2=silent
    print \"        [\\\"sync_backward\\\"] = 3,\"            # 3=disable
    print \"        [\\\"custom_server\\\"] = \\\"https://magazines.ablz.au/koreader\\\",\"
    print \"        [\\\"username\\\"] = \\\"<API_KEY>\\\",\"
    print \"        [\\\"userkey\\\"] = \\\"<API_KEY>\\\",\"
    in_kosync=0; print; next
  }
  in_kosync && /\[\"(auto_sync|checksum_method|sync_forward|sync_backward|custom_server|username|userkey)\"\]/ { next }
  { print }
' /storage/emulated/0/koreader/settings.reader.lua > /tmp/sr.new && \
   mv /tmp/sr.new /storage/emulated/0/koreader/settings.reader.lua"
```

Add the OPDS catalog (uses basic auth, accepts the user's password — API
keys are not honoured on `/opds/*`, only on `/api/*` and `/koreader/*`):

```bash
ssh <device> "python3 - <<PY 2>/dev/null || lua - <<LUA
# (use whichever interpreter is on the device; or just edit by hand —
# the file is human-readable Lua)
LUA
PY"
```

In practice it's easier to add the catalog through the UI on first launch
(magnifying glass → OPDS Catalog → + → name + URL +
`<email>` + `<password>`).

### 4. Open KOReader, open any book, turn a page, exit

Verify on doc2:

```bash
ssh doc2 "sudo grep ' /koreader/' /var/log/nginx/access.log | tail"
```

You want to see `GET /koreader/syncs/progress/<hash> -> 200` (pull on open)
and `PUT /koreader/syncs/progress -> 200` (push on close). 404 means
`hashKoreader` isn't populated yet (see landmine #1). 403 means the API
key didn't reach Komga as `X-Auth-User`.

Verify the stored progress directly:

```bash
curl -sS -H 'X-Auth-User: <API_KEY>' \
  https://magazines.ablz.au/koreader/syncs/progress/<HASH>
```

Returns `{"document": "...", "percentage": 0.4007..., "device": "...", ...}`.

## Reference: what each setting does

| Field in `["kosync"]` | Value | Meaning |
|---|---|---|
| `auto_sync` | `true` | Pull on open, push on close, push on page turn (25s debounce), push on suspend, pull on resume, push/pull on net up/down. **Required** for hands-off operation. |
| `checksum_method` | `0` | `0` = binary (MD5 of file). `1` = filename. Use 0 — Komga's `fileHashKoreader` is binary-based. |
| `sync_forward` | `2` | `1` = prompt before jump-forward, `2` = silent jump, `3` = disable. `2` for zero-tap cross-device. |
| `sync_backward` | `3` | Same enum. `3` = refuse jump-backward (avoids accidental "lost progress" from a misclick on another device). |
| `custom_server` | URL | Komga's kosync endpoint. Trailing slash optional. |
| `username` | API key | Sent as `X-Auth-User`. Komga's only auth check. |
| `userkey` | API key | Sent as `X-Auth-Key`. Komga ignores it. Must be non-empty to satisfy KOReader's local "is registered?" gate. |

## What happens cross-device

Phone reads to 40 %, exits → push fires, Komga stores
`{document, percentage, progress, device, device_id}`.

Boox opens the same EPUB (must be the **identical file** — KOReader matches
by binary hash, so an EPUB re-encoded by Calibre will not match a Komga-
delivered original) → pull fires, KOReader compares stored `percentage`
against local, sees ahead, applies `sync_forward` policy. With `=2`, jumps
silently. With `=1`, "Sync to page N?" dialog (one tap).

If the device is offline at exit, push retries on next network-up event
(plugin hooks `_onNetworkConnected`). Nothing queues persistently — if local
progress moves before a successful retry, the unsynced delta is lost. In
practice this never bites because the next page turn re-triggers a push.

## Common gotchas, ranked

1. **"It worked yesterday, today it 404s on every PUT"** — someone re-created
   the library (or a fresh scan reset hashes). Re-run `komga-sync.service`
   or PATCH `hashKoreader=true` + analyze.
2. **"Settings keep reverting"** — KOReader is alive as a cached process.
   Force-stop via Android Settings before editing.
3. **"403 from Komga on every kosync call"** — `username` field doesn't hold
   the API key. Check `["kosync"]` block in `settings.reader.lua`.
4. **"Two devices, but progress doesn't sync"** — KOReader version. Older
   than 2026.03 has a Komga-specific pull bug ([koreader#14596](https://github.com/koreader/koreader/issues/14596)).
5. **"OPDS browsing works but sync doesn't"** — these use different auth.
   OPDS = HTTP basic auth with email+password. Kosync = `X-Auth-User` with
   API key. Both need to be configured separately.
6. **"Sync works for one EPUB but not another"** — the failing EPUB came
   from somewhere other than Komga (different binary hash). Re-download
   from Komga's OPDS to get the canonical file.

## How we figured this out (chronological)

For posterity. Future debugging shortcuts.

1. Set top-level `kosync_username` / `kosync_userkey` / `kosync_custom_server`
   in `settings.reader.lua` → KOReader showed "Register/Login", zero
   `/koreader/*` hits in nginx. Took a subagent reading
   `plugins/kosync.koplugin/main.lua` to realise the keys must be nested.
2. Moved into `["kosync"]` table with `userkey = MD5(api_key)` → still no
   hits. Cause: KOReader was alive as a cached Android process and saved
   its memory-state on top of our edit, stripping the new keys.
3. Force-stopped KOReader from Android Settings, re-applied nested edit →
   `/koreader/syncs/progress/<hash>` finally fired, but 404. Subagent had
   also confirmed Komga ignores `X-Auth-Key`, so we set `username = API_KEY`.
4. Auth fixed; 404 remained. Inspected the book's metadata: `fileHash` set,
   `fileHashKoreader: null`. Library had `hashKoreader: false`. Flipped via
   API + analyze → hash populated → kosync PUT returned 200.
5. Total time from "should be a 5-min job" to working: ~3 hours, across
   ~8 false leads. Most of the time was on the cached-process problem (#2);
   second most on assuming standard kosync auth (#3).

## See also

* [komga.md](./komga.md) — Komga server architecture, libraries,
  monitoring
* [komga-sync.md](./komga-sync.md) — daily metadata sync (now also owns
  the `hashKoreader` ensure step)
* [magazines.md](./magazines.md) — top-of-stack overview
* KOReader kosync plugin source:
  https://github.com/koreader/koreader/blob/master/plugins/kosync.koplugin/main.lua
* Komga koreader integration:
  https://komga.org/docs/guides/koreader/
