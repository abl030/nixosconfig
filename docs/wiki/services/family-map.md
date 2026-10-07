# Family-history map (`family.ablz.au`)

**Status:** deployed 2026-09-29 on doc1 (`homelab.services.familyMap`)
**Source:** `~/family-history/maps/site/` on doc1 (repo
`git.ablz.au/abl030/family-history`, built by the family-history agent); aerial tiles
in `/var/lib/family-map/tiles` on doc1's local NVMe (not in git, not backed up:
regenerable from the masters in `/mnt/data/Life/Andy/Genealogy/Barrett-Lennard/Maps/masters`
on tower NFS)

## Design

Same shape as [cullen-carbon-dashboard](cullen-carbon-dashboard.md): a static
site served live from the working checkout, so pulling or editing `~/family-history`
on doc1 is live on the next load with no rebuild. Whatever is in the main
`~/family-history` checkout is served; work in a `~/family-history` worktree goes live once
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
  local tile cache.
- **Why local (2026-10-01):** the tile build writes tens of thousands of small
  PNGs per year. Over the tower NFS share each create/write took 100–400 ms
  (Unraid's share layer; ping 0.18 ms), about 6 files/s, so a 1942 rebuild took
  90+ minutes with 30 CPUs at under 1% and the old tree's `rmtree` hours more.
  Local ext4 on doc1's NVMe managed ~7,000 files/s. Masters stay on NFS (read
  once per build); generated tiles and the build's `.build-tmp` scratch live in
  `/var/lib/family-map/tiles` (same filesystem, so each year's swap is an atomic
  rename). The Linux page cache covers RAM caching (2.5 GB of tiles vs ~22 GB
  cache); tmpfs measured no faster and would break the atomic rename.
- nginx masks `/mnt` by default (#257); the maps and tiles binds no longer need
  `/mnt/data`, so this module no longer sets `RequiresMountsFor` (the podcast
  vhost still does).

## Access: LAN plus one tailnet share, never public

The 1953–2026 Landgate imagery is a private research copy and must not be
served publicly. The site's README allows "LAN/VPN/auth only". `family.ablz.au`
stays on `homelab.localProxy` (RFC1918 DNS). Do not add a Cloudflare tunnel or
any public proxy without first removing or replacing the Landgate layers.

**Tailnet share for Dad (2026-10-01):** `familymap.ablz.au` is a
`homelab.tailscaleShare.family-map` node (`familymap`, `tag:share`) on **doc2**,
not doc1. Its Caddy reverse-proxies over the LAN to `https://family.ablz.au`
with `upstreamHostHeader = true`, so doc1's nginx vhost and allowlist still
apply. It lives on doc2 so the bastion gets no podman runtime and no
auto-updated images. Access control is node sharing: share the `familymap`
machine only with family tailnets (Tailscale admin → Machines → familymap →
Share). The existing `autogroup:shared → tag:share` TCP 80/443 grant covers
sharees, so no ACL change was needed. Revoke a sharee in the same admin page.

```text
Dad's tailnet → familymap (ts-family-map, doc2) → caddy-family-map
             → https://family.ablz.au (doc1 192.168.1.29, LAN) → 127.0.0.1:8852
```

## Operations

- New GeoJSON or `eras-additions-*.md` files are picked up automatically once
  listed in `config.js` and symlinked into `site/data/` (served names must match
  `[A-Za-z0-9._-]+\.(geojson|md)`).
- If `~/family-history/maps` or the tiles directory is deleted
  and recreated as a directory, nginx holds the old mount:
  `sudo systemctl restart nginx`.
- Kuma monitors: `Family map` (page) and `Family map tiles` (manifest, now local; no longer fails when the NAS is down).
- Rebuild tiles: in `~/family-history/maps`, `nix-shell -p gdal "python3.withPackages(ps: [ps.pillow ps.numpy ps.scipy])" --run "python3 tools/build_tiles.py --years 1942"` (writes to `/var/lib/family-map/tiles`). An old NFS copy of the tiles may remain at `/mnt/data/.../Maps/tiles`; delete it on the tower itself, not over NFS.

## Verify

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' https://family.ablz.au/                       # 200
curl -fsS -o /dev/null -w '%{http_code}\n' https://family.ablz.au/tiles/manifest.json    # 200
curl -fsS -o /dev/null -w '%{http_code}\n' https://family.ablz.au/data/osm-roads.geojson # 200
curl -s   -o /dev/null -w '%{http_code}\n' https://family.ablz.au/../README.md           # 404
```
