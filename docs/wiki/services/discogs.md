# Discogs

**Last updated:** 2026-07-28
**Status:** dedicated unprivileged LXC canary on CT 102 (`192.168.1.44`); frozen `doc2` source retained for rollback
**Owner:** `modules/nixos/services/discogs.nix`
**Issues:** #228, #53

Discogs is a local CC0 dump mirror. The canary runs native PostgreSQL and the
Rust API in dedicated unprivileged CT 102; the former doc2 nspawn database is
retained as the rollback source. It serves the JSON API at `discogs.ablz.au`
and directly on LAN port `8086`. See
[metadata-mirror-lxc-migration](../infrastructure/metadata-mirror-lxc-migration.md)
for storage, migration, verification, and rollback details.

## Health Contract

`GET /health` returns `status = "ok"` only after the mirror has imported release
data. `status = "awaiting_import"` means the API process is reachable but the
mirror is not ready for cratedigger or Beets metadata use.

The Uptime Kuma monitor and cratedigger metadata gate both check JSON state, not
only HTTP 200.

## Cratedigger Boundary

Discogs import is part of the cratedigger maintenance boundary. Cratedigger owns
that coordination policy from doc2 through
`cratedigger-discogs-import-remote.service`:

1. Enters the `discogs-import` hold with `cratedigger-metadata-gate`.
2. Uses doc2's machine key through a restricted forced-command SSH boundary to
   start the importer on CT 102. The guest's local import timer is disabled.
3. Runs the dump import, which drops and recreates mirror tables, with up to four
   coordinated attempts.
4. Releases only the `discogs-import` hold after a successful import.
5. Calls `resume-if-clear`, which resumes cratedigger only if MusicBrainz and
   Discogs probes both pass and no other hold reason remains.

If the import fails, the hold remains in place across retries so cratedigger
does not run against an empty or transitioning mirror.

## Representative Probe

The current representative release probe is `/api/releases/83182`, which resolves
to OK Computer in the local mirror. Keep this as a cheap sanity check unless the
mirror stops carrying it.

## Least Privilege Notes

- Discogs and cratedigger database credentials remain separate.
- Import coordination uses root-owned systemd services, a restricted
  forced-command machine key, and one exact passwordless `systemctl start
  discogs-import.service` sudo rule; it exposes neither a shell nor writable
  shared state.
- PostgreSQL runs natively only because CT 102 is a dedicated unprivileged
  service boundary; setup/auth/ownership policy still comes from
  `modules/nixos/lib/mk-pg-container.nix`.
