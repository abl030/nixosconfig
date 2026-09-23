# Rolling flake update (doc1)

Status: unblocked 2026-09-23 (5 of 6 groups landed; `rest` held by a hermes-agent
plugin break). Speed-ups landed; robustness items still open (below).

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
  for every failed run: group failure, abort, timeout or kill. A run that still
  pushed (fresh heartbeat) pages yellow at priority 6 and resets the streak.
  Otherwise the title says how many nights in a row, the body gives the
  last-green time from master's heartbeat and the last log lines, and the
  priority is 8, or 10 from the second night.
  The streak lives in `/var/lib/rolling-flake-update/failure-streak` and the
  updater resets it after a fully green run. The Hermes RCA still follows as
  explanation.
- `rolling-flake-update-stale.timer` (09:00 daily, doc1 only) pages if
  master's heartbeat is older than 36h and no failure page went out in the last
  20h, i.e. the updater is not running at all. Priority 8, or 10 from 72h.
- Removed the `nixosconfig.cachix.org` substituter fleet-wide. It served 0 of
  ~2,500 substituted paths, but as the last substituter it was queried (~0.4s
  per miss, against ~0.05s for the LAN mirror) for every local-only path.

## First unblocked run (2026-09-23 08:19 → 09:55)

Landed mongodb80 (21 min), core (29 min, 12 days of nixpkgs), yt-dlp (12 min),
llm and nvchad, plus the heartbeat; push-deploy activated every host. `rest`
failed a real check: the new `hermes-agent` input no longer enables the
`ntfy-platform` plugin (`aiPortabilityCheck` →
`check-hermes-ntfy-runtime.py`), so all ~25 `rest` inputs stay held.

Where the time goes after the catch-up (sampled every 15s): each group is
mostly **single-threaded evaluation**, with one `nix` process at ~100% of one
core and zero builders for minutes while 29 cores idle.
`nix flake check` evaluates the fleet (~2.5 min), then `populate_cache.sh`
evaluates and builds the 12 hosts one at a time (~3 min eval, plus any build).
That is six times a night. A single slow derivation also serializes the
fleet: in the yt-dlp group, `mealie` held `doc2` (and every later host) for
about 7 min at a load of 2.

## Speed-ups (implemented 2026-09-23)

1. **All groups at once, split only on failure** (`try_all_groups` in
   `scripts/rolling_flake_update.sh`). Every group's inputs and the MongoDB
   patch are updated together and verified in one pass, then committed as one
   `rolling: <changed groups>` commit. If the update, build or commit fails,
   the tree is restored and the old per-group transactions run as before, so a
   bad input still only holds back its own group. `ONLY_GROUP` runs (and the
   test fixtures) skip the combined pass.
2. **Parallel evaluation, one build** (`scripts/populate_cache.sh`).
   `nix-eval-jobs` (3 workers, 6 GiB each) evaluates checks, packages, dev
   shells, every NixOS system and every Home Manager activation in parallel.
   One `nix build --keep-going` then builds all of them with doc1's full
   parallelism, and the `<host>-system` / `<host>-home` GC roots are refreshed
   for push-deploy. This replaces `FULL_CHECK=1 nix flake check` plus the
   host-by-host loop; host systems are built directly, which also sidesteps the
   `nix/checks/default.nix` NixOS/HM check shadowing. Measured: 286 s for the
   whole fleet (73 top-level derivations, 40 builders at peak) versus about
   10-12 min per group before.
3. **yt-dlp tip for the CLI only** (`nix/overlay.nix`). The top-level
   `yt-dlp` still rides upstream tip; it is used by cratedigger's ingest worker
   (via `${pkgs.yt-dlp}/bin` on PATH), `podcast.nix` and the shell scripts.
   A `pythonPackagesExtensions` entry rebuilds `python3Packages.yt-dlp` from
   the original nixpkgs package, so Python dependants (mealie, ...) are
   identical to nixpkgs and substitute from cache. Verified: the library and
   mealie drvs equal vanilla nixpkgs.
4. **Pure evaluation.** Both the combined pass and the per-group fallback
   evaluate with `--flake .#` and no `--impure`. The not-yet-committed lock
   change is in tracked files, so pure flake evaluation still sees it.
   nix-eval-jobs does not use the flake eval cache; the parallel workers are
   the speed-up.

Dropped from the old flake check: schema validation of non-derivation outputs
(apps, overlays, modules). Everything that builds is still built.

## Still to do (durable)

- Push after each group passes, and have the TERM handler push what already
  passed.
- Cache-aware nixpkgs bumps: reject revisions whose closure needs upstream
  source builds, or split `core`.
- Check free disk space before the run; make `persist_group_failure` writes
  best-effort; set `min-free`/`max-free`.
- Per-group time budget that still pushes and heartbeats when exceeded.
