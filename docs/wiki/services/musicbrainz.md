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

`musicbrainz.service` is a readiness aggregate. It requires the PostgreSQL
nspawn unit and all OCI container units, then runs API, DB, AMQP broker, and SIR
trigger verification before the service is considered started.

`musicbrainz-build-images.service` verifies that the local upstream MusicBrainz
images exist and only builds missing images from the pinned `inputs.musicbrainz-docker`
source. Existing local images are reused because runtime Dockerfile builds depend
on mutable Ubuntu package mirrors and proved brittle during deployment.
`musicbrainz-token.service` extracts the replication token before the web
container bind-mounts it. `musicbrainz-retire-compose` removes legacy compose
containers/volumes once and creates the shared `musicbrainz` podman network.
Compose must not be reintroduced as steady-state runtime; translate upstream
compose changes into explicit OCI entries.

## Maintenance Flow

1. `sudo cratedigger-metadata-gate hold musicbrainz-maintenance`
2. `sudo systemctl restart musicbrainz.service`
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
- Exit non-zero on any remaining failure so the systemd unit goes to
  `failed`.

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

1. **errorPattern `MusicBrainz replication failed`** — Loki match on
   `LoadReplicationChanges failed|Schema sequence mismatch` in
   `musicbrainz-replication.service` journal. threshold=0 (single-shot;
   the unit runs once daily). Validates that auto-heal didn't engage.

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
- Valkey is pinned by digest, not a mutable tag.
- The Nix-built LRCLIB image runs as numeric UID/GID `65532:65532` and owns only
  its SQLite state directory.
- Upstream MusicBrainz, indexer, RabbitMQ, and Solr images retain their entrypoint
  user behavior; forcing arbitrary UIDs there risks breaking their startup
  scripts and state ownership. RabbitMQ, Solr, and Valkey drop their main
  processes to service users at runtime.
- Cratedigger owns the metadata gate policy and installs MusicBrainz systemd
  drop-ins. MusicBrainz only owns its provider runtime and verification.
