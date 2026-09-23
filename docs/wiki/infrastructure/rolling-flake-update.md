# Rolling flake update (doc1)

Status: unblocked 2026-09-23. Durable robustness fixes are still open (below).

`rolling-flake-update.service` runs nightly at 23:00 AWST on doc1. It updates
flake inputs in groups (`mongodb80`, `core`, `yt-dlp`, `llm`, `nvchad`,
`rest`), builds every host, commits, writes the signed heartbeat
`fleet/freshness.json` and pushes Forgejo master once at the end.
Implementation: `modules/nixos/ci/rolling-flake-update.nix`,
`scripts/rolling_flake_update.sh`.

## Incident: 2026-09-12 → 2026-09-22, 11 failed nights

No run completed after 2026-09-11 23:44, so no host got package updates. Config
commits still deployed: a stale heartbeat only logs `FLEET-FRESHNESS FAIL`, it
does not block `fleet-update`. mrnews posts stalled too, which is how it was
found ([mrnews](../services/mrnews.md)).

| Run | Outcome | Page |
|---|---|---|
| 09-12, 09-15..09-21 | killed by `TimeoutStartSec=4h` at 03:00 | none |
| 09-13 | disk full, rollback "failed", aborted | Hermes RCA #5784, prio 8 |
| 09-14 | disk full, aborted | Hermes RCA #5835, prio 5 |
| 09-22 | killed at 03:00 (new TERM handler) | Hermes RCA #6007, prio 5 |

Root causes:

- **Serialized builds.** `NIX_CONFIG = "max-jobs = 1\ncores = 1"` had been
  added for MongoDB's SCons source build, which went away 2026-09-06. doc1's 30
  CPUs sat about 2% busy while about 4,500 derivations built one at a time.
- **Every group re-evaluates the whole fleet twice** (`FULL_CHECK=1 nix flake
  check --impure` plus `populate_cache.sh`). Peak was 15G RSS plus 12G swap on
  a ballooned 24-46G VM.
- **Push only at the end**, so a timeout discards groups that already passed,
  heartbeat included.
- **One-off causes:** `/` filled up on 09-13/14 (since grown; the artifact
  `mkdir` hitting ENOSPC was counted as a rollback failure). Hydra-broken or
  uncached leaves also failed `core`: `nodejs-slim-26.9.0` tests, and
  `buildGo125Module` removed while sops-nix was not yet in `core`.

Why it was quiet:

1. A timeout kill sent nothing until the TERM trap landed on 09-22.
2. The hourly staleness page was retired on 2026-06-13 (c15ba015, alert
   dedup: "the bot pages on failure"). Nothing consumed `FLEET-FRESHNESS FAIL`.
3. Hermes chose the title and priority of the pages that did go out: prio 5,
   no failure streak, no "last green".

## Changes on 2026-09-23

- `NIX_CONFIG` override removed, so builds use doc1's defaults (max-jobs 30,
  all cores).
- `TimeoutStartSec` raised from 4h to 6h. `MemoryHigh=20G` caps the updater's
  own evaluation (builds run under nix-daemon). `restartIfChanged = false`, so
  doc1's 03:10 switch cannot kill a run.
- `OnFailure=rolling-flake-update-alert.service`
  (`scripts/rolling_flake_update_alert.sh failure`) sends a direct Gotify page
  for every failed run: group failure, abort, timeout or kill. The title says
  how many nights in a row; the body gives the last-green time from master's
  heartbeat and the last log lines. Priority is 8, or 10 from the second night.
  The streak lives in `/var/lib/rolling-flake-update/failure-streak` and the
  updater resets it after a fully green run. The Hermes RCA still follows as
  explanation.
- `rolling-flake-update-stale.timer` (09:00 daily, doc1 only) pages if
  master's heartbeat is older than 36h and no failure page went out in the last
  20h, i.e. the updater is not running at all. Priority 8, or 10 from 72h.

## Still to do (durable)

- Push after each group passes, and have the TERM handler push what already
  passed.
- One full check per night instead of per group; build hosts in separate
  processes. Fix the `nix/checks/default.nix` `//` shadowing, where the HM
  checks overwrite the NixOS host checks, so the flake check builds no host
  system.
- Cache-aware nixpkgs bumps: reject revisions whose closure needs upstream
  source builds, or split `core`.
- Check free disk space before the run; make `persist_group_failure` writes
  best-effort; set `min-free`/`max-free`.
- Per-group time budget that still pushes and heartbeats when exceeded.
