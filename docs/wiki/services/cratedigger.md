# Cratedigger

**Last updated:** 2026-05-14
**Status:** active on `doc2`
**Owner:** `modules/nixos/services/cratedigger.nix`
**Issue:** #228

Cratedigger is the local Soulseek download pipeline and request UI behind
`music.ablz.au`. It is intentionally coupled to exactly two local metadata APIs:

- MusicBrainz `/ws/2`, served by `homelab.services.musicbrainz`.
- Discogs JSON API, served by `homelab.services.discogs`.

LRCLIB, iTunes, Amazon, Last.fm, albumart.org, Cover Art Archive reachability,
and other optional Beets enrichers are not cratedigger availability gates.

## Metadata Gate

The metadata gate helper is installed as `cratedigger-metadata-gate`. It owns
root-only state under `/run/cratedigger-metadata-gate/holds` and accepts only
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

The gate deliberately does not stop `container@cratedigger-db.service`,
`cratedigger-db-migrate.service`, or `redis-cratedigger.service`; those are
state plumbing and do not generate metadata API traffic by themselves.

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

MusicBrainz database maintenance uses the `musicbrainz-maintenance` hold. See
`docs/wiki/services/musicbrainz.md` for the external PostgreSQL cutover guard.

## Probe Shape

The helper uses local loopback endpoints on doc2, not LAN literals or public
FQDNs:

- `http://127.0.0.1:5200/ws/2/release` with a low-limit Radiohead / OK Computer search.
- `http://127.0.0.1:8086/health`, requiring `status = "ok"`.
- `http://127.0.0.1:8086/api/releases/83182`, currently OK Computer in the Discogs mirror.

These probes are intentionally lightweight and use short timeouts so the gate
does not become another source of API load.

This is a narrow exception to the repo's DNS-first rule. The gate is checking the
same-host local service boundary and must not depend on Cloudflare, nginx, DNS,
or public proxy health when deciding whether cratedigger should be allowed to
hit local metadata APIs.

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
