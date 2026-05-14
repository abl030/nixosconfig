# MusicBrainz

**Last updated:** 2026-05-14
**Status:** active on `doc2`; external PostgreSQL and OCI migration completed 2026-05-14
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

`musicbrainz-build-images.service` builds the local upstream MusicBrainz images
from the pinned `inputs.musicbrainz-docker` source. `musicbrainz-retire-compose`
removes legacy compose containers/volumes once and creates the shared
`musicbrainz` podman network. Compose must not be reintroduced as steady-state
runtime; translate upstream compose changes into explicit OCI entries.

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

## Least Privilege Notes

- PostgreSQL TCP auth stays on the `mk-pg-container` scram-sha-256 path.
- There is no compose-owned service in steady-state config.
- The database password lives in a narrow pgpass-style SOPS secret, not in the
  broader MusicBrainz env file.
- The host-side pgpass secret is root-only. `mk-pg-container` copies it inside
  the nspawn container to a private postgres-readable runtime file before setup.
- The remaining MusicBrainz env secret contains only the replication token.
- Cratedigger owns the metadata gate policy and installs MusicBrainz systemd
  drop-ins. MusicBrainz only owns its provider runtime and verification.
