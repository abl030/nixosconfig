# Music Pipeline Postmortem — 2026-02-15

## What We Built

Automated music acquisition pipeline: **Lidarr** (want list) -> **Soularr** (bridge) -> **slskd** (Soulseek downloads), with NZBGet as a secondary download source via Usenet/Newznab indexers. All running as podman containers on doc1 (proxmox-vm).

## What Went Wrong (and token cost)

### 1. arr MCP was broken out of the box (HIGH token cost)

**Problem:** `mcp-arr-server` npm package lists `@modelcontextprotocol/sdk` as `devDependency` instead of `dependency`. npx only installs runtime deps, so the server crashes on import. Additionally, the binary is named `mcp-arr`, not `mcp-arr-server`.

**Fix:** `npx -y -p @modelcontextprotocol/sdk -p mcp-arr-server mcp-arr`

**Generalization:** Third-party MCP servers from npm are unreliable. Don't trust packaging.

### 2. arr MCP has no write operations (VERY HIGH token cost)

**Problem:** The MCP only has read tools — no "add artist", "monitor album", "set quality profile", "force grab release", or "manual import". Every write operation required raw `curl` to Lidarr's API, which meant:
- Looking up API endpoints
- Constructing JSON payloads
- Debugging response errors
- Multiple round-trips per operation

**Token cost:** ~60% of total session tokens were spent on raw API calls that should have been single tool invocations.

**Generalization:** An MCP without write operations is almost useless for automation. Read-only gives you visibility but no agency.

### 3. Unicode hyphen in artist name (HIGH token cost)

**Problem:** MusicBrainz stores "Lord Jah‐Monte Ogbon" with U+2011 (NON-BREAKING HYPHEN). NZB release names use U+002D (HYPHEN-MINUS). Lidarr's release parser splits on ASCII hyphens, so it parsed:
- Artist: "Lord Jah"
- Album: "Monte Ogbon"
- Result: "Unknown Artist" rejection

This also caused directory name mismatches — we created a directory with an ASCII hyphen but Lidarr expected the Unicode hyphen.

**Fix:** Modified the push title to remove the internal hyphen, then manually copied files to the Unicode-named directory.

**Generalization:** Unicode normalization is a recurring issue with music metadata. Any MCP we build must handle this.

### 4. NZBGet path mapping not configured (MEDIUM token cost)

**Problem:** NZBGet runs on the Unraid NAS. Its internal `/downloads/completed/Music/` path maps to `/mnt/data/Media/Temp/completed/Music/` on the NAS, but Lidarr's `/downloads` volume only maps to `/mnt/data/Media/Temp/slskd` (the slskd downloads). Lidarr couldn't find NZBGet's completed files.

**Fix:** Manually copied files from NZBGet's output to Lidarr's music library, then triggered rescan.

**Long-term fix needed:** Either:
- Add a second volume mount to Lidarr for `/mnt/data/Media/Temp:/nzbget-downloads`
- Add a remote path mapping: `/downloads/completed` -> correct container path
- Or route ALL downloads through a common path

### 5. Soularr quality settings iteration (LOW token cost)

**Problem:** Had to iterate through quality settings:
1. Started with FLAC-first (default) -> downloaded FLAC that would be rejected by 320 profile
2. Changed to mp3-320-only -> niche album not found
3. Changed to cascading: mp3 320 > flac > any mp3

**Generalization:** Quality profiles should be set up correctly ONCE. Document the cascade pattern.

### 6. SoulseekMCP doesn't exist on npm (LOW token cost)

**Problem:** `@jotraynor/soulseekmcp` was never published. The wrapper script can never work via npx.

**Fix:** Updated script to support local builds via `SOULSEEKMCP_PATH` env var.

**Generalization:** Always verify npm package existence before wiring up MCP wrappers.

## Infrastructure Issues Found

### Volume Mapping Gap
```
Lidarr container volumes:
  /config  -> /mnt/docker/music/lidarr          (config)
  /music   -> /mnt/data/Media/Music/AI           (library)
  /downloads -> /mnt/data/Media/Temp/slskd       (slskd downloads ONLY)

NZBGet completed path:
  /downloads/completed/Music/ -> /mnt/data/Media/Temp/completed/Music/  (NOT visible to Lidarr!)
```

### Missing Lidarr Remote Path Mapping
NZBGet reports paths as `/downloads/completed/Music/...` but Lidarr has no mapping to translate this to a container-accessible path.

## MCPs We Need to Build

### 1. Custom Lidarr MCP (nixosconfig-v3y) — HIGHEST PRIORITY

**Why:** 60%+ of token waste was from missing Lidarr write tools.

**API docs:** https://lidarr.audio/docs/api/

**Tools needed:**

| Tool | Lidarr API | Why |
|------|-----------|-----|
| `add_artist` | `POST /api/v1/artist` | Add artist by MusicBrainz ID with root folder + quality profile |
| `monitor_album` | `PUT /api/v1/album/{id}` | Toggle monitoring on specific albums |
| `monitor_artist` | `PUT /api/v1/artist/{id}` | Toggle artist monitoring + monitorNewItems |
| `set_quality_profile` | `PUT /api/v1/artist/{id}` | Change artist quality profile |
| `search_artist` | `GET /api/v1/artist/lookup` | Search by name or MusicBrainz ID |
| `list_artists` | `GET /api/v1/artist` | Already exists in arr MCP |
| `list_albums` | `GET /api/v1/album?artistId=` | Already exists |
| `get_queue` | `GET /api/v1/queue` | Already exists |
| `get_wanted` | `GET /api/v1/wanted/missing` | Show wanted/missing albums |
| `search_album` | `POST /api/v1/command` (AlbumSearch) | Already exists |
| `search_releases` | `GET /api/v1/release?albumId=` | Interactive search results |
| `grab_release` | `POST /api/v1/release` | Force-grab a specific release |
| `manual_import` | `POST /api/v1/command` (ManualImport) | Import files from path |
| `remove_queue_item` | `DELETE /api/v1/queue/{id}` | Cancel/remove downloads |
| `get_quality_profiles` | `GET /api/v1/qualityprofile` | Already exists |
| `update_quality_profile` | `PUT /api/v1/qualityprofile/{id}` | Modify profile settings |
| `get_root_folders` | `GET /api/v1/rootfolder` | Already exists |
| `add_root_folder` | `POST /api/v1/rootfolder` | Create new root folder |
| `rescan_artist` | `POST /api/v1/command` (RescanArtist) | Re-scan artist library |
| `get_history` | `GET /api/v1/history` | View import/grab history |

**Design notes:**
- Accept MusicBrainz IDs directly (not just Lidarr IDs)
- Handle Unicode normalization for artist names
- Default quality profile and root folder from env vars
- `add_artist` should be a single call: name/MBID -> monitored with defaults

### 2. Custom slskd MCP (nixosconfig-cnz) — MEDIUM PRIORITY

**Why:** Checking download status required `podman exec wget` chains.

**API docs:** https://github.com/slskd/slskd/blob/master/docs/api.md

**Tools needed:**

| Tool | slskd API | Why |
|------|----------|-----|
| `get_status` | `GET /api/v1/application` | Connection status, version |
| `get_downloads` | `GET /api/v1/transfers/downloads/{username}` | Active download progress |
| `search` | `POST /api/v1/searches` | Search Soulseek network |
| `get_search_results` | `GET /api/v1/searches/{id}` | Get search results |
| `browse_peer` | `GET /api/v1/peers/{username}/browse` | Browse a peer's shares |

### 3. NZBGet MCP — LOW PRIORITY (but would have saved pain today)

**Why:** NZBGet is the Usenet download client. No visibility into its state from Claude.

**API docs:** https://nzbget.com/docs/api/

**Tools needed:**

| Tool | NZBGet API | Why |
|------|-----------|-----|
| `get_status` | `status` | Queue size, download speed |
| `list_downloads` | `listgroups` | Active/completed downloads |
| `get_history` | `history` | Completed download history |
| `add_nzb_url` | `append` | Add NZB by URL |

## Quality Profile Setup (Reference)

**Lidarr "320" profile (id: 3):**
- Accepts: ALL qualities (Trash through Lossless)
- Upgrade: enabled
- Cutoff: High Quality Lossy (contains MP3-320)
- Behavior: grabs anything available, keeps upgrading until MP3-320

**Soularr `allowed_filetypes` order:**
```ini
allowed_filetypes = mp3 320,flac 24/192,flac 16/44.1,flac,mp3
```
Searches in preference order. First match wins per album.

## Path Architecture (Current)

```
NAS (192.168.1.2:/mnt/user/data) mounted at /mnt/data on all VMs
├── Media/
│   ├── Music/
│   │   ├── Ali/              (existing collection)
│   │   ├── Me/               (existing collection)
│   │   ├── New/              (existing collection)
│   │   ├── Tagged/           (existing collection)
│   │   └── AI/               (Lidarr-managed)
│   └── Temp/
│       ├── slskd/            (slskd active downloads)
│       │   └── incomplete/   (slskd in-progress)
│       └── completed/
│           └── Music/        (NZBGet completed - NOT mapped to Lidarr!)
└── music/                    (OLD path, can be removed)
    └── ai/                   (empty, migrated to Media/Music/AI)
```

## Action Items

1. **Build Lidarr MCP** — nixosconfig-v3y — this alone would have saved 60%+ of tokens
2. **Build slskd MCP** — nixosconfig-cnz — saves podman exec chains
3. **Fix NZBGet volume mapping** — add `/mnt/data/Media/Temp/completed:/nzbget-completed` to Lidarr container + remote path mapping
4. **Clean up old path** — remove `/mnt/data/music/` directory
5. **Build NZBGet MCP** — low priority but completes the pipeline visibility
6. **Remove soulseek from .mcp.json** — until we have a working implementation, it just errors on startup
