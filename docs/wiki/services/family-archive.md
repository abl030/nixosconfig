# Family source archive viewer (`sources.ablz.au`)

**Status:** pilot, deployed 2026-10-07 on doc1 (`homelab.services.familyArchive`)
**Source:** the catalogue in `~/family-history/catalogue/` (repo
`git.ablz.au/abl030/family-history`). `fh build` writes the site to
`/var/lib/family-archive/site`. The originals live once, in the NAS archive at
`/mnt/data/Life/Andy/Genealogy/Archive/<source ID>/`.

## Design

```text
browser → doc1 nginx :443 sources.ablz.au (localProxy TLS/ACME, LAN DNS)
        → 127.0.0.1:8853 static server
            /            → /var/lib/family-archive/site (fh build output)
            /o/<ID>/<f>  → NAS archive, read-only bind, source-ID pattern only
            /tiles/…     → /var/lib/family-map/tiles (local NVMe), manifest and
                           <year>/<z>/<x>/<y> tiles only
            /basemap/…   → /var/lib/family-archive/basemap (local NVMe),
                           world.pmtiles and detail.pmtiles only
```

- The map's street map is self-hosted (2026-10-24): `fh basemap` cuts a
  world file (zoom 8, ~560 MB) and a detail file (zoom 15, ~7.7 GB: Australia,
  Britain and Ireland, the Netherlands, and a box round every other located
  place) from a Protomaps OpenStreetMap build, and the browser draws them
  with protomaps-leaflet. Nothing streams from OpenStreetMap's tile servers,
  which were slow and once refused the site outright.

- The site's map (`/map/` and every place page, family-history issue #7)
  draws aerial photographs from the tile cache that family.ablz.au also uses.
  The tiles are cut from local copies of the masters
  (`/var/lib/family-map/masters`, mirrored from the NAS) because reading the
  masters over NFS was too slow; `fh build` only reads the manifest, never an
  image. Landgate years are a private research copy, so the site stays
  LAN/family-only. family.ablz.au is to be removed once its history features
  are in the catalogue (issue #7); the tile cache's tmpfiles rule then moves
  here.

- The site is generated HTML plus small derivatives: region crops,
  thumbnails, and page images for PDFs. It is regenerable, so it isn't backed
  up. Rebuild it with `~/family-history/bin/fh build`.
- Originals are served straight from the NAS rather than copied. Saved web
  pages (`.html` originals) get a CSP `sandbox` header, so third-party markup
  can't run scripts or reach the origin.
- LAN-only by default: the archive holds certificates and papers of living
  people. It is **not** on the doc2 tailscale share that gives Dad the map.
  Since 2026-10-09 Mum's house gets it through its own share node,
  `familysources.ablz.au` (doc2), granted only to her router
  (`mumrouter`). See [mum-site-gateway](../infrastructure/mum-site-gateway.md).
- nginx binds both paths with `-`, so a NAS outage doesn't stop nginx; the
  originals return 404 until nginx restarts after the NAS is back.

## Operations

- Rebuild after catalogue changes: `cd ~/family-history && bin/fh build`
  (incremental; derivatives are stamped by hash).
- Check the catalogue: `bin/fh validate` (`--hash` re-hashes every original).
