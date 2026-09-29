# Family-history map (`family.ablz.au`)

**Status:** deployed 2026-09-29 on doc1 (`homelab.services.familyMap`)
**Source:** `~/agents/docs/wiki/family-history/maps/site/` on doc1 (repo
`git.ablz.au/abl030/agents`, built by the family-history agent); aerial tiles
in `/mnt/data/Life/Andy/Genealogy/Barrett-Lennard/Maps/tiles` (tower NFS, not
in git)

## Design

Same shape as [cullen-carbon-dashboard](cullen-carbon-dashboard.md): a static
site served live from the working checkout, so pulling or editing `~/agents`
on doc1 is live on the next load with no rebuild. Whatever is in the main
`~/agents` checkout is served; work in an `~/agents` worktree goes live once
merged and the main checkout is fast-forwarded.

```text
browser → doc1 nginx :443 family.ablz.au (localProxy TLS/ACME, LAN DNS)
        → 127.0.0.1:8852 static server
            /, *.js, *.css, data/*.geojson|md, vendor/leaflet/*  → /run/family-map/site
            /tiles/<year>/<z>/<x>/<y>.png, /tiles/manifest.json   → /run/family-map-tiles
```

- The whole `maps/` directory is bound read-only (not just `site/`) because
  `site/data/*` are relative symlinks into `../../data/`. Only the files the
  page loads are allowlisted; the README, tools and indexes 404.
- `site/tiles` is an absolute symlink for local `python3 -m http.server` use.
  nginx ignores it and serves `/tiles/` from a separate read-only bind of the
  NFS tile cache.
- nginx masks `/mnt` by default (#257); this module adds the tile bind plus
  `RequiresMountsFor=/mnt/data` (already present for the podcast vhost).

## Access: LAN only, deliberately

The 1953–2026 Landgate imagery is a private research copy and must not be
served publicly (the site's own `config.js`/README say so). Keep this on
`homelab.localProxy` (RFC1918 DNS). Do not add a Cloudflare tunnel, a public
proxy, or a tailscale-share without first removing or replacing the Landgate
layers.

## Operations

- New GeoJSON or `eras-additions-*.md` files are picked up automatically once
  listed in `config.js` and symlinked into `site/data/` (served names must match
  `[A-Za-z0-9._-]+\.(geojson|md)`).
- If `~/agents/docs/wiki/family-history/maps` or the tiles directory is deleted
  and recreated as a directory, nginx holds the old mount:
  `sudo systemctl restart nginx`.
- Kuma monitors: `Family map` (page) and `Family map tiles` (manifest via NFS).

## Verify

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' https://family.ablz.au/                       # 200
curl -fsS -o /dev/null -w '%{http_code}\n' https://family.ablz.au/tiles/manifest.json    # 200
curl -fsS -o /dev/null -w '%{http_code}\n' https://family.ablz.au/data/osm-roads.geojson # 200
curl -s   -o /dev/null -w '%{http_code}\n' https://family.ablz.au/../README.md           # 404
```
