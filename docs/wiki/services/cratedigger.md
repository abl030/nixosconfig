# Cratedigger

**Last updated:** 2026-07-30
**Status:** active on `doc2`
**Owner:** `modules/nixos/services/cratedigger.nix`, `modules/nixos/ci/cratedigger-daily-checks.nix`
**Issue:** #228, [Cratedigger #498](https://github.com/abl030/cratedigger/issues/498)

Cratedigger is the local Soulseek download pipeline and request UI behind
`music.ablz.au`. It is intentionally coupled to exactly two local metadata APIs:

- MusicBrainz `/ws/2`, served by `homelab.services.musicbrainz`.
- Discogs JSON API, served by `homelab.services.discogs`.

LRCLIB, iTunes, Amazon, Last.fm, albumart.org, Cover Art Archive reachability,
and other optional Beets enrichers are not cratedigger availability gates.

## Daily unstable compatibility checks

Doc1 runs `cratedigger-daily-checks.service` every day at 05:05 AWST. The unit
executes the runner from `inputs.cratedigger-src`; Cratedigger owns the test and
lock-update semantics, while nixosconfig owns scheduling, persistent Hypothesis
state, journald output, and the existing RCA-first/Gotify-fallback notification.

The runner checks out current GitHub `main`, updates its standalone `flake.lock`,
then runs whole-repository Pyright, the deterministic suite, `nix flake check`,
the lifecycle world burst, the full fuzz burst, and the mirror-harness smoke.
Every test stage runs even after an earlier test failure so one notification has
the complete result. A fully green candidate pushes one lock-only commit;
anything red pushes nothing. Fleet yt-dlp deliberately tracks upstream git tip
through an independently updated source input, so extractor fixes do not wait
for a nixpkgs release. The service otherwise owns no urllib3, idna, lxml,
msgpack, soupsieve, Flask, or ffmpeg version.

Replay databases and complete failed fuzz logs live under
`/var/lib/cratedigger-daily-checks`. The temporary candidate checkout is private
to the unit and removed at exit.

Failure notifications are deliberately summaries, not raw journal tails. They
report lock disposition, every stage result, the generated-fuzz outcome, unique
Pyright errors, deterministic failed-test IDs with their rerun command, and a
bounded live-world result. Progress lines and passing-test noise are excluded.
The message includes the exact `_SYSTEMD_INVOCATION_ID` command for retrieving
the complete journal when deeper diagnosis is needed.

The same unit always finishes with doc2's deployed strict
`pipeline-cli audit world --json`, after both successful and failed candidate
runs. The strict audit remains nonzero for every current violation. A second
root-only wrapper classifies that exact report against a schema-versioned,
digest-only authority state under
`/var/lib/cratedigger-live-world-audit/known-debt.json`; the raw report and its
production identities stay on doc2.

The tracked gate is green only when the current violations are an exact stable
or shrinking subset of the persisted member fingerprints. It atomically removes
converged members, but any new member, changed cause/identity, same-count
replacement, growth, missing state, or corrupt state is red without rewriting
the authority. The daily post-step logs only aggregate classifier counts. Its
failure cannot stop a green candidate from updating `flake.lock`, because the
runner has already finished, but it does make the single daily unit red and uses
the same RCA/Gotify path. The initial state is an explicit one-time rollout
action and must never be regenerated to recover a failing daily gate. See
[Cratedigger #910](https://github.com/abl030/cratedigger/issues/910).

The #910 rollout authority is exactly the twice-observed 658-member cohort:
420 `current_evidence_missing` and 238
`evidence_fingerprint_mismatch`. Initialization must stop if a fresh strict
audit differs from those code counts, contains another code, or has duplicate
members. After initialization, deleting or replacing the state to admit a red
result is forbidden; investigate the reported new/changed members instead.

## Metadata Gate

The metadata gate helper is installed as `cratedigger-metadata-gate`. It owns
root-only persistent safety state under
`/var/lib/cratedigger-metadata-gate/holds` and accepts only
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
- `cratedigger-youtube-ingest.service`

The gate deliberately does not stop `container@cratedigger-db.service`,
`cratedigger-db-migrate.service`, or `redis-cratedigger.service`; those are
state plumbing and do not generate metadata API traffic by themselves.

Lifecycle migrations can also place receipt-owned start inhibitors at:

- `/var/lib/cratedigger-metadata-gate/inhibit-cratedigger.service`
- `/var/lib/cratedigger-metadata-gate/inhibit-cratedigger-youtube-ingest.service`

These root-evaluated conditions independently withhold the main pipeline or
YouTube ingest when the ordinary metadata hold is released. They are outside
`holds/`, so `release` and `resume-if-clear` never remove them; only the
deployment receipt that created an inhibitor may do so. Web, importer, and
preview remain free of these controlled-start conditions.

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

## Runtime Config Convergence

`/var/lib/cratedigger/config.ini` is mutable secret-bearing runtime state, not a
Nix-store config file. The upstream Cratedigger NixOS module owns a dedicated
`cratedigger-config-render.service` oneshot that renders it during boot and each
system convergence, independently of application `ExecCondition` gates.
Application units retain fail-fast render fallbacks, so none can successfully
start against a missing or stale file.

Only `cratedigger.service`, which owns the singleton pipeline lock, uses the
pipeline pre-start wrapper that may clear `.cratedigger.lock`. Web, importer,
preview, unfindable, YouTube ingest, and the deployment renderer are render-only
and must never remove or recreate that lock. This is pinned by the upstream
module VM: every application unit is held, the independent renderer materializes
a non-default config, and a renderer restart repairs a corrupted file while
preserving both lock inode and contents.

This fixes the 2026-07-19 deployment incident where systemd evaluated the
metadata gate's `ExecCondition` before application `ExecStartPre`, leaving the
old localhost slskd URL in mutable state even though the evaluated Nix template
already contained `http://192.168.21.2:5030`.

MusicBrainz maintenance uses the `musicbrainz-maintenance` hold. MusicBrainz now
runs in dedicated CT 100, so an operator enters this hold on doc2 before a
provider deployment or disruptive restart and releases it only after the remote
representative probe succeeds. Discogs's automatic monthly import is coordinated
by doc2's `discogs-import.service`: it enters the durable hold, invokes CT 102
through a restricted forced-command machine identity, and releases only after
all metadata probes pass.

## Probe Shape

The helper uses direct LAN endpoints for the dedicated metadata guests, not
public FQDNs:

- `http://192.168.1.43:5200/ws/2/release` with a low-limit Radiohead / OK Computer search.
- `http://192.168.1.44:8086/health`, requiring `status = "ok"`.
- `http://192.168.1.44:8086/api/releases/83182`, currently OK Computer in the Discogs mirror.

These probes are intentionally lightweight and use short timeouts so the gate
does not become another source of API load.

This is a narrow exception to the repo's DNS-first rule. The gate is checking
the provider service boundary and must not depend on Cloudflare, nginx, DNS, or
public proxy health when deciding whether Cratedigger may use metadata APIs.

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

## `/mnt` sandbox boundary

Every Cratedigger app unit gets a private empty `/mnt`. The timer-driven
`cratedigger` and `cratedigger-unfindable` units retain the established writable
`dataDir`, Music root, and slskd download binds. The four long-running units are
narrower: web/importer see Music read-only and write only `dataDir/processing`,
`dataDir/beets-db`, `Music/Beets`, `Music/Incoming`, and slskd (the importer
also writes the `Music/Re-download` tracking parent); preview writes processing
and slskd but sees Music read-only; YouTube ingest writes only `Music/Incoming`.
This is deliberate preparation for upstream
`ProtectSystem=strict`: a writable `BindPaths` mount itself grants write access,
so a narrower upstream `ReadWritePaths` cannot revoke it.

The metadata-gate `ExecCondition` for web/importer/preview/YouTube ingest is a
fixed Nix-store command prefixed with systemd `+`, with only
`/var/lib/cratedigger-metadata-gate` added to those units' `ReadWritePaths`. It
can record a dependency hold without granting the services broad `/var/lib`
authority. Holds survive reboot; this is mandatory for remote imports that may
continue while doc2 restarts.

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
