# Cratedigger

**Last updated:** 2026-06-29
**Status:** active on `doc2`
**Owner:** `modules/nixos/services/cratedigger.nix`
**Issue:** #228

Cratedigger is the local Soulseek download pipeline and request UI behind
`music.ablz.au`. It is intentionally coupled to exactly two local metadata APIs:

- MusicBrainz `/ws/2`, served by `homelab.services.musicbrainz`.
- Discogs JSON API, served by `homelab.services.discogs`.

LRCLIB, iTunes, Amazon, Last.fm, albumart.org, Cover Art Archive reachability,
and other optional Beets enrichers are not cratedigger availability gates.

## Metadata Gate

The metadata gate helper is installed as `cratedigger-metadata-gate`. It owns
root-only state under `/run/cratedigger-metadata-gate/holds` and accepts only
fixed hold reasons:

- `manual`
- `dependency`
- `discogs-import`
- `musicbrainz-maintenance`

The fixed guarded unit set is:

- `cratedigger.timer`
- `cratedigger.service`
- `cratedigger-web.service`
- `cratedigger-importer.service`
- `cratedigger-import-preview-worker.service`

The gate deliberately does not stop `container@cratedigger-db.service`,
`cratedigger-db-migrate.service`, or `redis-cratedigger.service`; those are
state plumbing and do not generate metadata API traffic by themselves.

`cratedigger-temp-clean.timer` removes stale `/tmp/cratedigger-import-preview-*`
and `/tmp/cratedigger-v0-probe-*` directories older than six hours. This keeps
large preview/probe scratch from filling doc2's root filesystem without touching
active short-lived jobs.

## Operator Commands

```bash
sudo cratedigger-metadata-gate status
sudo cratedigger-metadata-gate hold manual
sudo cratedigger-metadata-gate release manual
sudo cratedigger-metadata-gate resume-if-clear
```

`resume-if-clear` only starts cratedigger when no hold reasons remain and both
local metadata probes pass. The dependency watchdog can clear only the
`dependency` hold; manual, Discogs import, and MusicBrainz maintenance holds are
released only by their owner.

MusicBrainz maintenance uses the `musicbrainz-maintenance` hold. The migration
is complete; this hold now protects ordinary provider restarts and rebuilds.
Cratedigger attaches the hold before MusicBrainz retire/build/token/container
units, then releases it only after `musicbrainz.service` verification succeeds.

## Probe Shape

The helper uses local loopback endpoints on doc2, not LAN literals or public
FQDNs:

- `http://127.0.0.1:5200/ws/2/release` with a low-limit Radiohead / OK Computer search.
- `http://127.0.0.1:8086/health`, requiring `status = "ok"`.
- `http://127.0.0.1:8086/api/releases/83182`, currently OK Computer in the Discogs mirror.

These probes are intentionally lightweight and use short timeouts so the gate
does not become another source of API load.

This is a narrow exception to the repo's DNS-first rule. The gate is checking the
same-host local service boundary and must not depend on Cloudflare, nginx, DNS,
or public proxy health when deciding whether cratedigger should be allowed to
hit local metadata APIs.

## Least Privilege Notes

- Gate state is root-owned and not group-writable.
- Callers cannot pass arbitrary unit names or systemctl arguments.
- The helper reads no secrets.
- Discogs import coordinates through the fixed helper commands; it does not
  share Discogs database credentials with cratedigger.
- Cratedigger runtime/notifier secrets are readable by root and the dedicated
  `cratedigger-ops` operator group only, not the broad `users` group and not the
  network-exposed `slskd` service.
- Cratedigger still runs as root because it writes across slskd download state,
  Beets staging/import paths, and media library paths.
- Slskd and cratedigger share the bounded `music-import` group. The upstream
  zero-umask behavior is patched in the Nix source input so imported library
  directories settle at `0775`, not `0777`.

## Incidents

### 2026-06-29 — beets 2.11→2.12 bump broke every import

A nightly closure bump moved beets `2.11.0 → 2.12.0`, which did the beets 2.x
library refactor: `get_path_formats` moved from `beets.ui` to
`beets.util.pathformats` (and now requires a config subview), `get_replacements`
became a `Library` staticmethod, and `Library.__init__` dropped its
`path_formats`/`replacements` positional args (it now derives both from
`config["paths"]`/`config["replace"]` itself). The harness
(`harness/beets_harness.py` in `inputs.cratedigger-src`) still used the beets 1.x
`from beets.ui import get_path_formats, get_replacements` + 4-arg `Library(...)`
form, so it crashed at import (line 27) on **every** force-import, automation
import, and beets validation — `FORCE-IMPORT FAILED ... ImportError: cannot
import name 'get_path_formats' from 'beets.ui'`. The preview worker was
unaffected (it never opens the beets library).

Fix: `modules/nixos/services/cratedigger-beets2-library-api.patch` adapts the
harness to the 2.x API (drop the `beets.ui` import, pass only `(library,
directory)`; config-derived path formats/replacements are preserved). This is a
homelab stopgap — upstream the same change to `github:abl030/cratedigger` and
drop the patch.

**Resolution (same day).** The patch above fixed only breakage #1 (the harness
crashed at import). Once it landed, force-imports ran again but *upgrade*
imports of already-in-library albums still failed with `decision=import_failed
… Post-import: release <mbid> has multiple beets album rows [X, Y]`. beets 2.x
ALSO replaced the duplicate-resolution hook: the 1.x
`ImportSession.resolve_duplicate` + `task.should_remove_duplicates = True` is
gone; 2.x calls `session.get_duplicate_action(task, found_duplicates) ->
DuplicateAction` and removes the old album in `manipulate_files` only when the
action is `REMOVE`. The harness's stale `resolve_duplicate` override was
silently never called, so every upgrade added a second album row and tripped
cratedigger's post-import single-row guard. Both fixes (Library/import API +
`get_duplicate_action`), plus a `lib/beets_distance.py` autotag fix and a
real-beets subprocess contract test (the harness unit tests mock beets, which
is why the API drift shipped undetected), landed upstream in
`github:abl030/cratedigger` PR #462. `cratedigger-src` was bumped
`8486be16 → 25c15e0` and the stopgap patch removed (nixosconfig `4862ac45`).
Verified live: an upgrade force-import now logs `[DUP-GUARD] Allowing beets
remove …` → `[POST-FLIGHT OK]` (single row) → `decision=import`.
