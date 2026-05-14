# Youtarr

Date researched: 2026-05-14
Status: MariaDB extraction in progress for issue #231
Related: issue #231, #228, #230, #232

## Service Shape

Youtarr runs on doc2 with state under `/mnt/virtio/youtarr` and is exposed at
`https://youtarr.ablz.au/` through `modules/nixos/services/youtarr.nix`.

The app remains an OCI container. The database is moving out of upstream's
bundled `mariadb:10.3` OCI container into the fleet-owned nspawn MariaDB helper:

- App unit: `podman-youtarr.service`
- Database unit: `container@youtarr-db.service`
- MariaDB package: `pkgs.mariadb_1011`
- Database address: `192.168.100.19:3306`
- Database/user: `youtarr` / `youtarr`
- New database state: `/mnt/virtio/youtarr/mariadb-nspawn/mysql`
- Import marker: `/mnt/virtio/youtarr/mariadb-nspawn/imported-from-oci`
- Former OCI database state: `/mnt/virtio/youtarr/database`

MariaDB 10.3 reached EOL on 2023-05-25. Upstream Youtarr's compose defaults
still use `mariadb:10.3`, but upstream also supports external database mode via
`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, and `DB_NAME`.

## Secret Layout

`secrets/hosts/doc2/youtarr-db.env` is the narrow database secret used by both
sides of the connection:

- `MYSQL_PASSWORD` feeds `mk-mariadb-container` while setting the MariaDB user
  password.
- `DB_PASSWORD` feeds the Youtarr app container.

The module derives non-secret database settings from Nix:

- `DB_HOST = 192.168.100.19`
- `DB_PORT = 3306`
- `DB_USER = youtarr`
- `DB_NAME = youtarr`

Do not put database passwords back into `modules/nixos/services/youtarr.nix`.

## Image Pinning

The Youtarr app image was pinned on 2026-05-14 while extracting the database:

```text
docker.io/dialmaster/youtarr@sha256:8c891a4f96e7b7c37d9915e7b78b919fe03f0aacd87eab76d751f761003e5ee1
```

This is intentionally service-local hardening, not a fleet-wide OCI image
policy. To update later:

1. Inspect the upstream Youtarr image or release you intend to run.
2. Replace the digest in `modules/nixos/services/youtarr.nix`.
3. Rebuild/deploy doc2.
4. Verify `https://youtarr.ablz.au/` and `podman-youtarr.service`.
5. Record the new digest and reason here.

## Migration Runbook

Preflight on 2026-05-14:

- Source container: `youtarr-db`
- Source image: `docker.io/library/mariadb:10.3`
- Source MariaDB version: `10.3.39-MariaDB-1:10.3.39+maria~ubu2004`
- Source database/user: `youtarr` / `youtarr`
- Source table count: 9
- Current public check before stopping writes: `https://youtarr.ablz.au/` returned HTTP 200

Final dump with writes stopped:

- App unit stopped: `podman-youtarr.service`
- DB unit left running for dump: `podman-youtarr-db.service`
- Dump: `/mnt/virtio/youtarr/migration-20260514-091204/youtarr.sql`
- Dump checksum: `/mnt/virtio/youtarr/migration-20260514-091204/youtarr.sql.sha256`
- Dump size: 336K
- SHA256: `16728d47b6c3082f9e9d27ef271aa330065aa4bb362c9b50e3457b5e9b5faf6e`

Expected cutover shape:

1. Stop writes by stopping `podman-youtarr.service`.
2. Dump the old MariaDB 10.3 database from `podman-youtarr-db.service`.
3. Keep `/mnt/virtio/youtarr/database` intact as rollback state.
4. Deploy the NixOS config with `container@youtarr-db.service`.
5. Restore the dump into MariaDB 10.11.
6. Run the MariaDB post-upgrade check/upgrade step appropriate for 10.11.
7. Touch `/mnt/virtio/youtarr/mariadb-nspawn/imported-from-oci`.
8. Start `podman-youtarr.service`.
9. Verify public HTTP, logs, table counts, and stored Youtarr state.
10. Keep the old database directory until at least one normal rebuild/restart
   cycle succeeds.

Exact commands belong in this document after the live source state has been
verified during implementation.

The app unit has an `ExecCondition` migration gate: if the old
`/mnt/virtio/youtarr/database/mysql` directory exists and the import marker is
absent, systemd skips `podman-youtarr.service` instead of starting Youtarr
against an empty new database. This is intentional during the first deployment.

## Rollback During Migration Window

Rollback is available only while `/mnt/virtio/youtarr/database` remains intact.
The intended rollback is:

1. Restore the pre-migration module revision that starts `podman-youtarr-db`.
2. Rebuild doc2 from that revision.
3. Start `podman-youtarr-db.service` and `podman-youtarr.service`.
4. Verify `https://youtarr.ablz.au/`.

Once the old directory is deleted, recovery means restoring a dump into the
nspawn MariaDB runtime, not reverting to the old OCI database container.

## Verification Checklist

After migration:

- `container@youtarr-db.service` is active.
- `podman-youtarr.service` is active.
- `podman-youtarr-db.service` is not generated.
- `/mnt/virtio/youtarr/mariadb-nspawn/imported-from-oci` exists.
- `https://youtarr.ablz.au/` returns normally.
- Youtarr logs show successful database connectivity.
- The app image is digest-pinned.
- No plaintext database password appears in the module.
