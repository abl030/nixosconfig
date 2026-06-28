# MusicBrainz

**Last updated:** 2026-05-23
**Status:** active on `doc2`; external PostgreSQL and OCI migration completed 2026-05-14; replication fail-loud + schema auto-heal landed 2026-05-23
**Owner:** `modules/nixos/services/musicbrainz.nix`
**Issue:** #228

MusicBrainz serves the local `/ws/2` API used by Beets and cratedigger. LRCLIB
runs in the same MusicBrainz operational boundary for Beets lyrics. LMD/Lidarr
Metadata was retired on 2026-05-14 and is no longer part of the active runtime,
monitoring, firewall exposure, or secret surface.

## Current Boundary

- MusicBrainz web/API port: `5200`
- LRCLIB port: `3300`
- Cratedigger gate: MusicBrainz `/ws/2` is a hard gate.
- Non-gates: LRCLIB and optional public Beets enrichment providers.

## PostgreSQL Ownership

The steady-state database boundary is a fleet-managed nspawn PostgreSQL service:

- Unit: `container@musicbrainz-db.service`
- Helper: `modules/nixos/lib/mk-pg-container.nix`
- Host slot: `hostNum = 10`
- DB host for OCI clients: `192.168.100.21`
- Data path: `/mnt/mirrors/musicbrainz/postgres-nspawn/postgres`
- PostgreSQL: nixpkgs `postgresql_18`
- Required extension package: `musicbrainz-pg-amqp`
- Application DB: `musicbrainz_db`
- DB user: `musicbrainz`
- Secret: `secrets/hosts/doc2/musicbrainz-pgpass.env`
- RabbitMQ bridge for AMQP triggers: `192.168.100.20:5672`

RabbitMQ is bound only on the host side of the MusicBrainz nspawn veth
(`192.168.100.20:5672`). That gives PostgreSQL's `pg_amqp` trigger functions a
broker they can reach without exposing RabbitMQ on the LAN.

## Runtime Layout

The old `podman compose` runtime was retired after the database migration.
Steady-state containers are explicit NixOS OCI units:

- `podman-musicbrainz-valkey-1.service`
- `podman-musicbrainz-mq-1.service`
- `podman-musicbrainz-search-1.service`
- `podman-musicbrainz-indexer-1.service`
- `podman-musicbrainz-musicbrainz-1.service`
- `podman-musicbrainz-lrclib-1.service`

`musicbrainz.service` is the DB-plane orchestration + verify unit. It requires
the PostgreSQL nspawn unit and `wants` (NOT `requires`) the five MB *app*
containers, then runs DB/AMQP-broker/SIR-trigger verification. It does **not**
own container lifecycle — the containers are `wantedBy multi-user.target` and are
**not** `partOf` it, so a verification failure can never tear the stack down. Web
`/ws/2` readiness lives in a separate, non-destructive `musicbrainz-ready.service`
(see "Readiness decoupling" below). `lrclib` is fully independent of all of the
above.

`musicbrainz-build-images.service` verifies that the local upstream MusicBrainz
images exist and only builds missing images from the pinned `inputs.musicbrainz-docker`
source. Existing local images are reused because runtime Dockerfile builds depend
on mutable Ubuntu package mirrors and proved brittle during deployment.
`musicbrainz-token.service` extracts the replication token before the web
container bind-mounts it. `musicbrainz-retire-compose` removes legacy compose
containers/volumes once and creates the shared `musicbrainz` podman network.
Compose must not be reintroduced as steady-state runtime; translate upstream
compose changes into explicit OCI entries.

## Readiness decoupling (2026-06-25 RCA)

**Symptom.** The `LRCLIB` Uptime-Kuma monitor paged "lrclib is down" repeatedly.
On doc2 the whole MusicBrainz stack was caught in a ~3-minute restart loop that
had not converged 6+ hours after the nightly auto-update reboot (`musicbrainz.service`
+ `multi-user.target` start jobs were still pending from boot).

**Root cause — two layers:**

1. *Proximate trigger.* The MB web container couldn't reach its dependencies. On
   2026-06-25, doc2's nightly auto-update reboot started **netavark 2.0.0, which
   broke container DNS** (see
   [netavark-2.0-dns-regression](../infrastructure/netavark-2.0-dns-regression.md)):
   the web container couldn't resolve `valkey`, so its wait-for-deps loop failed,
   it crash-looped, and `/ws/2` never became healthy → `apiVerifyScript` always
   failed. (The ~3-min loop period == `apiVerify`'s budget, which proves the
   DB-plane checks `dbVerify`/`amqpSetup` passed and `apiVerify` was the sole
   failure.) The web cold start is *also* genuinely heavy — webpack bundle +
   10-proc Plack + Solr-backed `/ws/2/release` — so the same teardown loop can be
   triggered by anything that delays readiness past apiVerify's budget, not just
   DNS. (Early in the investigation this looked like plain slowness-under-load; the
   real trigger was the DNS regression.)
2. *Architectural fault (the real bug).* `apiVerifyScript` ran inside
   `musicbrainz.service`'s `postStart`, and that unit **owned the container
   lifecycle**: every container was `partOf = musicbrainz.service` and the service
   `requires`-d them all. So when the web-readiness check gave up, `PartOf` tore
   down **all six containers** — including the web+Solr containers that just
   needed more time (so it could never converge) and the standalone **lrclib**
   service (Rust+sqlite, zero MB dependency), which is what paged. The readiness
   probe was destroying the very thing it was probing.

**Fix (commit on 2026-06-25).** Decouple lifecycle from verification:

- Removed `partOf = musicbrainz.service` from every container; the five MB app
  containers are now `wantedBy multi-user.target` and boot on their own.
- `musicbrainz.service` now only `requires` the PostgreSQL nspawn and `wants` the
  app containers (ordering, not failure-coupling); `postStart` keeps only the
  fast/deterministic `amqpSetup` + `dbVerify`, so it converges in seconds.
- Web `/ws/2` readiness moved to a new **`musicbrainz-ready.service`** — a patient
  (~10 min) oneshot that is `after` the web+search containers, `wantedBy`
  multi-user.target, and owns **nothing**. If it fails it pages (its own
  errorPattern, "web readiness failed") without tearing anything down — being
  patient is now free because it no longer kills what it waits on.
- **lrclib** is fully decoupled: not `partOf`, not pulled by `musicbrainz.service`,
  not dependent on `musicbrainz-build-images` (its image is Nix-built). It needs
  only the podman network (`retire-compose`) and its data mount, so its Kuma
  monitor now reflects lrclib's actual health.

**Why it didn't bite before:** the DNS plane worked under netavark 1.x, so the web
container resolved `valkey` and came up; the trigger was the reboot onto netavark
2.0.0, not gradual load. But the architectural fault is independent of the trigger —
after decoupling, a readiness failure from *any* cause (DNS, slow Solr warmup, a
crashing dependency) can no longer tear down the stack or flap lrclib. The netavark
regression itself is fixed separately by the 1.17.x pin (Forgejo #13).

## Maintenance Flow

1. `sudo cratedigger-metadata-gate hold musicbrainz-maintenance`
2. Restart the app containers directly (since they are no longer `partOf`
   `musicbrainz.service`, restarting that unit only re-runs verification):
   `sudo systemctl restart podman-musicbrainz-{valkey,mq,search,indexer,musicbrainz}-1.service`
   then `sudo systemctl restart musicbrainz.service musicbrainz-ready.service` to
   re-verify. (lrclib is independent — restart `podman-musicbrainz-lrclib-1.service`
   on its own only if lrclib itself needs it.)
3. Verify `/ws/2` health/search, replication readiness, LRCLIB, Discogs gate,
   and cratedigger resume.

Rollback artifacts are not retained after successful verification. A future full
rebuild should redownload upstream MusicBrainz dumps.

## 2026-05-14 Cutover Record

The live cutover used the `dump-restore` path:

- Old compose DB container: `musicbrainz-db-1`
- Old DB user: `abc`
- Temporary dump: `/mnt/mirrors/musicbrainz/dbdump/cutover-20260514T080208Z.dump`
  was removed after verification.
- Restored counts: `artist = 2872585`, `release = 5496911`
- Non-internal triggers restored: `39`
- Rollback ref recorded in marker: `github:abl030/nixosconfig/933fd9a1#doc2`
- Rollback artifacts retained: `false`

Post-restore ownership was narrowed to the `musicbrainz` database role for all
application relations. The compose DB and rollback paths were removed;
`container@musicbrainz-db.service` owns the real PostgreSQL data path.

Live verification after deployment:

- `musicbrainz.service`, `container@musicbrainz-db.service`, `discogs-api.service`,
  and cratedigger units active.
- `sudo cratedigger-metadata-gate status` showed no holds and probes `ok`.
- Local MusicBrainz `/ws/2` representative release query returned results.
- Discogs `/health` returned `status = ok`.
- `https://music.ablz.au/` returned HTTP 200.
- No LMD/Lidarr containers or `5001`/`8686` listeners remained.
- Temporary dump and old compose DB rollback paths were removed after
  verification.

## Replication Monitoring & Self-Heal (2026-05-23 incident)

### Background

The mirror silently froze from 2026-05-11 to 2026-05-23. MetaBrainz cut a
schema-change image (`v-2026-05-11.0-schema-change`, bumping replication
schema sequence 30 → 31); `LoadReplicationChanges` started refusing packets
with `Schema sequence mismatch - codebase is 31, database is 30`.

Three layered failures masked it:

1. Upstream `admin/cron/mirror.sh` does
   `./admin/replication/LoadReplicationChanges >> $MIRROR_LOG 2>&1 || { echo failed; }`,
   so any rc≠0 is captured and the script returns 0.
2. Our systemd unit had `ExecStart = podman exec ... replication.sh`,
   inheriting that swallowed rc=0 — unit "Finished" cleanly every night.
3. No state-based freshness check; the daily Kuma monitor only verified
   the LRCLIB endpoint.

Net: 13 days of no replication, no alert.

### Resilience layers

`replicationScript` in `musicbrainz.nix` wraps `replication.sh` to:

- Tee output to the journal.
- Detect `LoadReplicationChanges failed` and `Schema sequence mismatch`
  in stdout or `mirror.log`.
- For a one-step schema mismatch, run upstream `upgrade.sh` in-band
  (under `carton exec`, sourcing `/noninteractive.bash_env` for the
  image's local::lib env) and retry replication.
- **Classify the remaining (non-schema) failure (2026-06-28).** A *transient
  upstream fetch* failure — `LoadReplicationChanges` couldn't DOWNLOAD a packet
  (network/TLS/DNS blip to metabrainz.org; e.g. `SSL … unexpected eof`,
  `Died at … LoadReplicationChanges line 238`), with no apply/data error —
  **exits 0 and does NOT page**: it self-heals on the next run and the
  state-based freshness probe backstops a real stall. A real *apply/data*
  failure (a packet downloaded but failed to apply) or a failed schema
  auto-heal **exits 1 with an `[mb-replication] …` verdict line**. Detection is
  a `fetch_re` vs `apply_re` grep over stdout+`mirror.log`; ambiguous/unknown
  failures default to paging (fail safe).

The image's `upgrade.sh` has a few non-obvious requirements the wrapper
satisfies:

- It needs `carton exec` — bare invocation can't find `aliased.pm`.
- `carton` itself needs `local::lib` env (PATH, PERL5LIB, etc.) which
  the image's entrypoint dumps to `/noninteractive.bash_env`; podman
  exec bypasses the entrypoint so we source the dump explicitly. Use
  `;` not `&&` after sourcing — the file ends with a `[[ -n ... ]]`
  guard that returns 1 in our context.
- `DB_SCHEMA_SEQUENCE` env is the *current* DB version (the script
  asserts it equals `NEW_SCHEMA_SEQUENCE - 1 = 30` for a 30→31 jump);
  pass `db_seq`, not the codebase value.
- Pass `REPLICATION_TYPE=2` (RT_MIRROR) to skip the perl probe.
- `SKIP_EXPORT=1` since this is a mirror, not a master.
- In-container command paths must NOT be host `/nix/store` paths
  (Ubuntu container has no Nix store).

### Monitoring layers

Two independent signals — either one fires if replication is broken:

1. **errorPattern `MusicBrainz replication failed`** — Loki match in the
   `musicbrainz-replication.service` journal. threshold=0 (single-shot; the
   unit runs once daily).
   **As of 2026-06-28 it keys ONLY on the wrapper's own verdict lines**
   (`\[mb-replication\] (replication apply failed|upgrade\.sh failed|schema
   mismatch needs manual|retry still failed)`), NOT the raw upstream
   `LoadReplicationChanges failed (rc=255)` / `Schema sequence mismatch`
   strings we tee to the journal. Why: the wrapper is the decision authority —
   it has already excluded a transient fetch blip (exits 0) and a *successful*
   schema auto-heal (exits 0). Matching the raw strings used to **false-page**
   on both (a momentary metabrainz TLS hiccup at 03:00, and every clean
   auto-heal, since the raw diagnostics are still printed). Commit `dbd09c3f`.

2. **deepProbe `MusicBrainz replication freshness`** —
   `modules/nixos/services/probes/check-musicbrainz-replication.nix`.
   Hourly. Queries `replication_control.last_replication_date` via psql
   on the nspawn DB at `192.168.100.21:5432` using the
   `musicbrainz-pgpass` secret. Marks DOWN at >36h staleness. Pushes UP
   to Kuma on success.

### Timeout choice

`TimeoutStartSec = 14400s` (4 h) covers:

- Steady daily run: ~20 min for one packet's worth (`LoadReplicationChanges`
  loops via `goto NEXT_PACKET` until upstream returns 404 for the next
  sequence).
- In-band schema upgrade: ~1 min of DDL + VACUUM ANALYZE on the ~5 GB
  application schema.
- Recovery catch-up: worst observed was 11 days × ~24 hourly packets at
  ~1-3 min/packet = ~3 h.

Cron-frequency note: upstream packets are produced hourly but our
timer is `*-*-* 03:00:00` (daily). LoadReplicationChanges drains all
available packets per invocation via its NEXT_PACKET loop, so a daily
cadence is "wakes up once a day and catches up everything since
yesterday". Moving to hourly is a future optimisation, not a
correctness fix.

### Manual replays / debugging

```
# Check current DB state
sudo podman exec musicbrainz-musicbrainz-1 bash -c '. /noninteractive.bash_env; carton exec -- ./admin/psql MAINTENANCE -c "SELECT * FROM replication_control"'

# Force replication outside the unit (uses container's own lock):
sudo podman exec musicbrainz-musicbrainz-1 replication.sh

# Read the cron wrapper's swallowed-error log:
sudo podman exec musicbrainz-musicbrainz-1 tail -200 /musicbrainz-server/mirror.log

# Replay schema upgrade manually (matches what replicationScript does):
sudo podman exec \
  -e SKIP_EXPORT=1 -e SKIP_VACUUM=0 \
  -e DB_SCHEMA_SEQUENCE=<current-db-seq> -e REPLICATION_TYPE=2 \
  musicbrainz-musicbrainz-1 \
  bash -c '. /noninteractive.bash_env; carton exec -- ./upgrade.sh'
```

## Least Privilege Notes

- PostgreSQL TCP auth stays on the `mk-pg-container` scram-sha-256 path.
- There is no compose-owned service in steady-state config.
- The database password lives in a narrow pgpass-style SOPS secret, not in the
  broader MusicBrainz env file.
- The host-side pgpass secret is root-only. `mk-pg-container` copies it inside
  the nspawn container to a private postgres-readable runtime file before setup.
- The remaining MusicBrainz env secret contains only the replication token.
- The replication token is mounted as a read-only file; it is not passed through
  the web container environment.
- Valkey runs `:latest` with auto-pull (unpinned 2026-06-19, fleet policy). It's
  a stateless cache, so a version bump only costs a cold cache, no data risk.
- Solr (`mb-solr`) is **not** a registry tag-pin and is deliberately not
  auto-pulled: it's built locally from the `musicbrainz-docker` flake input via
  `--build-arg MB_SOLR_VERSION`, and that version is **schema-coupled** to the
  MusicBrainz server (also built from the same input). `4.1.0` is the current
  latest stable mb-solr AND the upstream default. Update it by bumping the
  `musicbrainz-docker` flake input (which moves server + solr together, reviewed)
  — the "flake-input pinning is fine" exception — not by chasing a mutable tag.
- The Nix-built LRCLIB image runs as numeric UID/GID `65532:65532` and owns only
  its SQLite state directory.
- Upstream MusicBrainz, indexer, RabbitMQ, and Solr images retain their entrypoint
  user behavior; forcing arbitrary UIDs there risks breaking their startup
  scripts and state ownership. RabbitMQ, Solr, and Valkey drop their main
  processes to service users at runtime.
- Cratedigger owns the metadata gate policy and installs MusicBrainz systemd
  drop-ins. MusicBrainz only owns its provider runtime and verification.
