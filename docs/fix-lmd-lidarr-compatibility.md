# Fix LMD/Lidarr Album Lookup Compatibility

## Problem

Lidarr 3.1.0 calls `GET /album/<artist-mbid>` on the self-hosted LMD (Lidarr Metadata Server), expecting it to return all albums for that artist. The LMD version we run (`blampe/lidarr.metadata:70a9707`) treats `/album/<mbid>` as a release group lookup, so sending an artist MBID returns 404.

Lidarr silently falls back to the upstream SkyHook API, so this was likely always broken — even before the doc1 → doc2 migration.

## Evidence

From Lidarr trace logs on doc2:

```
GET /search?type=artist&query=radiohead  → 200 OK (15KB, 15ms)  ✓
GET /album/a74b1b7f-...  (artist MBID)  → 404 Not Found         ✗
```

But the album endpoint works with a release group ID:

```
GET /album/b1392450-...  (OK Computer release group) → 200 OK   ✓
```

## LMD API Routes (from introspection)

The `70a9707` build registers these Quart routes at root level (no `/api/v0.4/` prefix):

```
/search              - artist/album search (works)
/search/artist       - artist search
/search/album        - album search
/artist/<mbid>       - artist detail (returns albums)
/album/<mbid>        - release group detail (NOT artist albums)
/series/<mbid>       - series detail
/spotify/*           - Spotify integration
/invalidate          - cache invalidation
```

Key: `ROOT_PATH` env var only affects redirects/Cloudflare URLs, NOT route registration.

## What Needs to Happen

One of these approaches:

### Option A: Update to newer LMD (hearring-aid)

The blampe/hearring-aid project (https://github.com/blampe/hearring-aid) is the successor. Check if newer versions have a `/album/` route that accepts artist MBIDs, or if there's a Lidarr plugin (Tubifarry) that changes how Lidarr talks to LMD.

Research:
- https://github.com/blampe/hearring-aid/blob/main/docs/self-hosted-mirror-setup.md
- https://github.com/blampe/hearring-aid/releases
- Check Docker Hub `blampe/lidarr.metadata` for newer tags

### Option B: Reverse proxy shim

Add an nginx location block that intercepts `GET /album/<artist-mbid>` requests, detects when the MBID is an artist (not a release group), and redirects to `/artist/<mbid>` instead. This would be a thin shim in the musicbrainz service module.

### Option C: Lidarr plugin (Tubifarry)

The hearring-aid docs reference a "Tubifarry" Lidarr plugin that may change how Lidarr communicates with LMD. Investigate if this resolves the routing mismatch. Would require using `blampe/lidarr` (plugins-enabled fork) instead of upstream Lidarr.

## Key Files

- `modules/nixos/services/musicbrainz.nix` — The musicbrainz stack module on doc2
- `hosts/doc2/configuration.nix` — doc2 host config (enables musicbrainz service)
- `modules/nixos/services/lidarr.nix` — Lidarr service module
- `stacks/musicbrainz/` — Old doc1 stack (for reference, no longer active)

## Current State

- MusicBrainz stack running on doc2 (192.168.1.35), 8 containers healthy
- LMD on port 5001, LRCLIB on 3300, MB Web on 5200
- Lidarr on doc2, metadatasource = `http://localhost:5001/`
- Lidarr MCP uses `https://lidarr.ablz.au` (nginx proxy, port 8686 not in firewall)
- Beads issue: `bd show nixosconfig-91b`

## Verification

After fixing, verify with:

```bash
# From doc2:
# 1. Lidarr trace log should show 200 for album lookup
sudo grep '5001' /mnt/virtio/lidarr/logs/lidarr.trace.txt

# 2. MCP should return albums
# In Claude Code: lidarr_search_album artist=Radiohead album="OK Computer"

# 3. Direct LMD test
curl -s "http://localhost:5001/album/a74b1b7f-71a5-4011-9441-d0b5e4122711" | python3 -m json.tool | head -5
```
