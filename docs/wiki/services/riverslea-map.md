# Riverslea historical map (`riverslea.ablz.au`)

**Status:** deployed 2026-10-01 on doc1 (`homelab.services.riversleaMap`)
**Source:** `~/riverslea-map/site/` on doc1 (project repo `~/riverslea-map`);
aerial tiles in `/var/lib/riverslea-map/tiles` on doc1's local NVMe (not in git,
not backed up: regenerable with the project's `tools/build_tiles.py`)

## Design

A copy of [family-map](family-map.md): a static Leaflet site served live from
the working checkout, so pulling or editing `~/riverslea-map` on doc1 is live
on the next load with no rebuild.

```text
browser → doc1 nginx :443 riverslea.ablz.au (localProxy TLS/ACME, LAN DNS)
        → 127.0.0.1:8853 static server
            /, *.js, *.css, data/*.geojson|md, data/eras.json, vendor/leaflet/*  → /run/riverslea-map/site
            /tiles/<year>/<z>/<x>/<y>.png, /tiles/manifest.json                    → /run/riverslea-map-tiles
```

- The whole repo is bound read-only (not just `site/`) because `site/data` is a
  relative symlink to `../data`. Only the files the page loads are allowlisted:
  `data/*.geojson|md` plus `data/eras.json` (the era list `app.js` fetches).
  Other `data/*.json` (build inputs), `data/cache/`, `tools/`, `docs/` and the
  README all 404.
- `site/tiles` is an absolute symlink for local `python3 -m http.server` use;
  point it at `/var/lib/riverslea-map/tiles`. nginx ignores it and serves
  `/tiles/` from a separate read-only bind of the tile cache.
- Tiles are on local disk, not the tower NFS share, for the reason recorded in
  [family-map](family-map.md) (NFS manages ~6 small-file creates/s; local ext4
  ~7,000/s). Keep any build scratch inside the tiles dir so swaps are atomic
  renames on one filesystem.

## Access: LAN only, deliberately

The Landgate imagery is a private research copy and must not be served
publicly. Keep this on `homelab.localProxy` (RFC1918 DNS). Do not add a
Cloudflare tunnel, a public proxy, or a tailscale-share without first removing
or replacing the Landgate layers.

## Operations

- New GeoJSON files are picked up once listed in `site/config.js` and present
  in `data/` (served names must match `[A-Za-z0-9._-]+\.(geojson|md)`). A new
  JSON file the page needs requires its own allowlist entry in
  `modules/nixos/services/riverslea-map.nix`.
- If `~/riverslea-map` or the tiles directory is deleted and recreated, nginx
  holds the old mount: `sudo systemctl restart nginx`.
- Kuma monitors: `Riverslea map` (page) and `Riverslea map tiles` (manifest;
  fails until tiles and `manifest.json` have been built).
- Build tiles with the project's `tools/build_tiles.py`, writing to
  `/var/lib/riverslea-map/tiles` (owned by abl030 via tmpfiles).

## Verify

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' https://riverslea.ablz.au/                        # 200
curl -fsS -o /dev/null -w '%{http_code}\n' https://riverslea.ablz.au/data/eras.json          # 200
curl -fsS -o /dev/null -w '%{http_code}\n' https://riverslea.ablz.au/tiles/manifest.json     # 200 once built
curl -s   -o /dev/null -w '%{http_code}\n' https://riverslea.ablz.au/../README.md            # 404
curl -s   -o /dev/null -w '%{http_code}\n' https://riverslea.ablz.au/data/research-features.json # 404
```
