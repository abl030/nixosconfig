# MusicBrainz

**Last updated:** 2026-05-14
**Status:** active on `doc2`; external PostgreSQL cutover completed 2026-05-14
**Owner:** `modules/nixos/services/musicbrainz.nix`
**Issue:** #228

MusicBrainz serves the local `/ws/2` API used by Beets and cratedigger. LRCLIB
continues to run in the same compose project for Beets lyrics. LMD/Lidarr
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
- DB host for compose clients: `192.168.100.21`
- Data path: `/mnt/mirrors/musicbrainz/postgres-nspawn/postgres`
- PostgreSQL: nixpkgs `postgresql_18`
- Required extension package: `musicbrainz-pg-amqp`
- Application DB: `musicbrainz_db`
- DB user: `musicbrainz`
- Secret: `secrets/hosts/doc2/musicbrainz-pgpass.env`
- RabbitMQ bridge for AMQP triggers: `192.168.100.20:5672`

The upstream compose `db` service is reset to an inert BusyBox shim so upstream
`docker-compose.yml` can still be layered without owning PostgreSQL state. The
rendered compose config must not show a PostgreSQL build, pghome/pgdata volume,
or 5432 exposure for that service.

The shim image is built by Nix and loaded locally before compose starts. It must
not use a mutable public image tag.

The compose `mq` service is bound only on the host side of the MusicBrainz
nspawn veth (`192.168.100.20:5672`). That gives PostgreSQL's `pg_amqp` trigger
functions a broker they can reach without exposing RabbitMQ on the LAN.

## Cutover Guard

`musicbrainz.service` has `restartIfChanged = false`; rebuilds should not
silently switch the database owner. Operators must start it manually during the
maintenance window after writing:

```text
/var/lib/musicbrainz-cutover/external-db-approved.json
```

The JSON must include:

- `path`: `dump-restore` or `rebuild-import`
- `sourceState`: what was verified about the old DB before cutover
- `rollbackRef`: git ref or flake ref for the pre-cutover config, or an empty
  string once rollback artifacts are intentionally removed
- `rollbackArtifactsRetained`: boolean; `false` means old DB rollback data has
  been deleted after verification
- `oldDataPaths`: old compose DB locations retained for rollback, or an empty
  array when `rollbackArtifactsRetained = false`
- `newDataPath`: `/mnt/mirrors/musicbrainz/postgres-nspawn/postgres`

The guard also verifies retained old data paths when
`rollbackArtifactsRetained = true`, the new DB path exists, `musicbrainz_db` is
populated, user tables are owned by `musicbrainz`, the `amqp` extension exists,
its broker row points at `192.168.100.20:5672`, and non-internal indexer
triggers exist. The marker alone is not enough.

Example shape:

```json
{
  "path": "dump-restore",
  "sourceState": {
    "postgres": "18.3",
    "database": "musicbrainz_db",
    "verifiedAt": "2026-05-14T00:00:00Z"
  },
  "rollbackRef": "github:abl030/nixosconfig/<commit>#doc2",
  "rollbackArtifactsRetained": false,
  "oldDataPaths": [],
  "newDataPath": "/mnt/mirrors/musicbrainz/postgres-nspawn/postgres"
}
```

If the marker is missing or malformed, `musicbrainz.service` refuses to start
and leaves the `musicbrainz-maintenance` cratedigger hold in place.

## Maintenance Flow

1. `sudo cratedigger-metadata-gate hold musicbrainz-maintenance`
2. Verify old DB health, version, table counts, and source data paths.
3. Stop the old compose DB writer.
4. Dump/restore into `musicbrainz_db` on `container@musicbrainz-db.service`, or
   deliberately rebuild/import from MusicBrainz dumps.
5. Verify object ownership is mapped to `musicbrainz`, not the old `abc` role.
   A dump/restore path should use `--no-owner --no-acl` or equivalent role
   remapping.
6. Write the cutover approval JSON.
7. `sudo systemctl start musicbrainz.service`; post-start runs the upstream SIR
   AMQP setup, pins the `pg_amqp` broker to the nspawn bridge, generates SIR
   triggers when missing, and verifies all of it before releasing cratedigger.
8. Verify `/ws/2` health/search, replication readiness, LRCLIB, Discogs gate,
   and cratedigger resume.

Rollback artifacts are not retained after successful verification. A future full
rebuild should redownload upstream MusicBrainz dumps.

## 2026-05-14 Cutover Record

The live cutover used the `dump-restore` path:

- Old DB container: `musicbrainz-db-1`
- Old DB user: `abc`
- Temporary dump: `/mnt/mirrors/musicbrainz/dbdump/cutover-20260514T080208Z.dump`
  was removed after verification.
- Restored counts: `artist = 2872585`, `release = 5496911`
- Non-internal triggers restored: `39`
- Rollback ref recorded in marker: `github:abl030/nixosconfig/933fd9a1#doc2`
- Rollback artifacts retained: `false`
- Approval marker: `/var/lib/musicbrainz-cutover/external-db-approved.json`

Post-restore ownership was narrowed to the `musicbrainz` database role for all
application relations. The compose DB is now the inert
`musicbrainz-db-disabled:latest` shim, while `container@musicbrainz-db.service`
owns the real PostgreSQL data path.

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
- There is no compose-owned PostgreSQL service in steady-state config.
- The database password lives in a narrow pgpass-style SOPS secret, not in the
  broader MusicBrainz env file or generated compose files.
- The host-side pgpass secret is root-only. `mk-pg-container` copies it inside
  the nspawn container to a private postgres-readable runtime file before setup.
- The remaining MusicBrainz env secret contains only the replication token.
- `musicbrainz.service` holds cratedigger during maintenance and releases only
  after API, DB, AMQP broker, and SIR trigger verification succeeds.
