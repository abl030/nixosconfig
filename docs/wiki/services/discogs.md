# Discogs

**Last updated:** 2026-05-14
**Status:** active on `doc2`
**Owner:** `modules/nixos/services/discogs.nix`
**Issue:** #228

Discogs is a local CC0 dump mirror backed by an isolated PostgreSQL nspawn
container. It serves the JSON API at `discogs.ablz.au` and local loopback port
`8086`.

## Health Contract

`GET /health` returns `status = "ok"` only after the mirror has imported release
data. `status = "awaiting_import"` means the API process is reachable but the
mirror is not ready for cratedigger or Beets metadata use.

The Uptime Kuma monitor and cratedigger metadata gate both check JSON state, not
only HTTP 200.

## Cratedigger Boundary

Discogs import is part of the cratedigger maintenance boundary. The
`discogs-import.service` wrapper:

1. Enters the `discogs-import` hold with `cratedigger-metadata-gate`.
2. Runs the dump import, which drops and recreates mirror tables.
3. Releases only the `discogs-import` hold after a successful import.
4. Calls `resume-if-clear`, which resumes cratedigger only if MusicBrainz and
   Discogs probes both pass and no other hold reason remains.

If the import fails, the hold remains in place across retries so cratedigger
does not run against an empty or transitioning mirror.

## Representative Probe

The current representative release probe is `/api/releases/83182`, which resolves
to OK Computer in the local mirror. Keep this as a cheap sanity check unless the
mirror stops carrying it.

## Least Privilege Notes

- Discogs and cratedigger database credentials remain separate.
- Import coordination uses root-owned systemd services and fixed helper commands;
  no sudoers rule or writable shared state is introduced.
- The Discogs PostgreSQL container remains isolated through
  `modules/nixos/lib/mk-pg-container.nix`.
