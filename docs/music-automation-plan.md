# Music Automation Plan: Soulseek → Lidarr → Plex Pipeline

**Goal**: Enable Claude Code to fulfill requests like "get me this album" by searching Soulseek, downloading, tagging, and making available in Plex.

**Date**: 2026-02-05
**Status**: Infrastructure code complete, manual setup remaining

---

## Decisions Made

| Question | Decision |
|----------|----------|
| **Host for slskd** | doc1 (main services VM) |
| **Host for Lidarr** | doc1 (already deployed, unused) |
| **Lidarr state** | Fresh start — nuke existing config |
| **Music library path** | `/mnt/data/music/ai` (new subfolder for AI-sourced) |
| **Soulseek credentials** | Existing account, store in sops |
| **Secrets storage** | sops-encrypted (consistent with repo pattern) |
| **Architecture** | Option C: Hybrid (Soularr daemon + direct MCP for immediate) |
| **Default quality** | 320kbps MP3 (overridable per request) |
| **Duplicate handling** | Skip and warn if exists in library |
| **Plex scanning** | Auto-scan enabled (no action needed) |
| **Notifications** | Gotify on download complete |
| **slskd MCP approach** | Try existing SoulseekMCP, generate from OpenAPI if gaps |
| **MCP server location** | Local (current pattern) |

---

## Proposed Architecture

```
User: "Get me Whiskeytown - Strangers Almanac"
                    │
                    ▼
            ┌───────────────┐
            │  Claude Code  │
            └───────┬───────┘
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   SoulseekMCP   Lidarr MCP   Plex MCP
        │           │           │
        ▼           ▼           ▼
      slskd      Lidarr       Plex
        │           │           │
        └─────┬─────┘           │
              ▼                 │
        Download Folder         │
              │                 │
              └────► Lidarr ────┘
                   (import/tag)
                        │
                        ▼
                  Music Library
                        │
                        ▼
                      Plex
```

### Option A: Full MCP Control (Maximum Flexibility)

Claude controls each step directly via MCP servers:
1. Search Soulseek via SoulseekMCP
2. Download via SoulseekMCP
3. Trigger Lidarr import via Lidarr MCP
4. Trigger Plex scan via Plex MCP

**Pros**: Full control, can handle edge cases, immediate feedback
**Cons**: More MCP servers to maintain, Claude orchestrates everything

### Option B: Soularr Daemon (Most Hands-Off)

Claude only adds to Lidarr's wanted list; Soularr daemon handles the rest:
1. Add album to Lidarr wanted list via Lidarr MCP
2. Soularr (daemon) monitors wanted list every 5 min
3. Soularr searches slskd and triggers download
4. Lidarr auto-imports from download folder
5. Plex auto-scans library

**Pros**: Simple, robust, handles retries/failures
**Cons**: Not immediate (5 min polling), less visibility

### Option C: Hybrid

Claude can do both — use Soularr for bulk/background, direct MCP for immediate requests.

---

## Components Required

### New Docker Services

| Service | Image | Purpose | Port |
|---------|-------|---------|------|
| slskd | `slskd/slskd` | Soulseek client with REST API | 5030 (web), 5031 (API) |
| soularr | `mrusse/soularr` | Lidarr ↔ slskd bridge | None (daemon) |

### Existing Services to Configure

| Service | Current State | Changes Needed |
|---------|---------------|----------------|
| Lidarr | Deployed on doc1, unused | Fresh config: root folder `/mnt/data/music/ai`, Soularr as download bridge |
| Plex | Working, auto-scan enabled | Add `/mnt/data/music/ai` to music library |

### MCP Servers to Add

| MCP Server | Source | Purpose |
|------------|--------|---------|
| SoulseekMCP | `@jotraynor/SoulseekMCP` | Direct Soulseek search/download |
| mcp-arr-server | `npm: mcp-arr-server` | Lidarr management |
| plex-mcp-server | `npm: plex-mcp` | Plex library scan/search |

---

## Implementation Status

### Completed (2026-02-05)

| Item | File | Notes |
|------|------|-------|
| Docker compose for slskd | `stacks/music/docker-compose.yml` | Added slskd service with volumes, ports 5030/5031 |
| Docker compose for soularr | `stacks/music/docker-compose.yml` | Daemon that bridges Lidarr wanted list → slskd |
| Firewall ports | `stacks/music/docker-compose.nix` | Added 5030, 5031 to firewallPorts |
| MCP wrapper: arr | `scripts/mcp-arr.sh` | Sources secrets, runs `npx -y mcp-arr-server` |
| MCP wrapper: soulseek | `scripts/mcp-soulseek.sh` | Sources secrets, runs soulseek MCP |
| MCP config | `.mcp.json` | Added `arr` and `soulseek` entries |
| NixOS MCP module | `modules/nixos/services/mcp.nix` | Added arr/soulseek options with sops integration |
| Secrets: arr-mcp.env | `secrets/arr-mcp.env` | sops-encrypted, has placeholder API key |
| Secrets: soulseek-mcp.env | `secrets/soulseek-mcp.env` | sops-encrypted, has placeholder credentials |
| Secrets: music.env | `secrets/music.env` | Updated with SOULSEEK_USERNAME/PASSWORD placeholders |
| Soularr config template | `stacks/music/soularr/config.yaml` | Template config, needs Lidarr API key |
| Quality gate | - | `check` passes |

**Note**: The MCP module is defined but NOT enabled in any host config yet. Nothing will run until you explicitly enable it.

### Remaining Manual Steps

```bash
# 1. Fill in your real Soulseek credentials
sops secrets/soulseek-mcp.env
# Change:
#   SOULSEEK_USERNAME=your_actual_username
#   SOULSEEK_PASSWORD=your_actual_password

sops secrets/music.env
# Change the SOULSEEK_USERNAME and SOULSEEK_PASSWORD lines

# 2. Enable the MCP module in proxmox-vm host config
#    Edit hosts/proxmox-vm/configuration.nix and add:
#
#    homelab.mcp = {
#      enable = true;
#      arr.enable = true;
#      soulseek.enable = true;
#    };

# 3. Create the AI music directory on doc1
ssh proxmox-vm 'mkdir -p /mnt/data/music/ai'

# 4. Deploy to doc1
nixos-rebuild switch --flake .#proxmox-vm --target-host proxmox-vm

# 5. Fresh Lidarr setup
#    - Browse to http://doc1:8686
#    - Complete initial setup wizard
#    - Settings → Media Management → Root Folder: /mnt/data/music/ai
#    - Settings → General → Copy the API Key

# 6. Update arr secrets with Lidarr API key
sops secrets/arr-mcp.env
# Change LIDARR_API_KEY to the key from Lidarr

# 7. Copy soularr config to doc1 and update it
scp stacks/music/soularr/config.yaml proxmox-vm:/mnt/data/music/soularr/
ssh proxmox-vm 'nano /mnt/data/music/soularr/config.yaml'
# Update the lidarr.api_key field with your Lidarr API key

# 8. Restart the music stack on doc1
ssh proxmox-vm 'systemctl --user restart podman-compose@music'

# 9. Verify services are running
ssh proxmox-vm 'podman ps | grep -E "slskd|soularr|lidarr"'

# 10. Test slskd web UI
#     Browse to http://doc1:5030
#     Should show slskd interface, check Settings for Soulseek connection status

# 11. Add Plex library (if not already done)
#     In Plex, add /mnt/data/music/ai as a Music library source
```

### Testing the Pipeline

Once setup is complete:

1. **Test Lidarr MCP**: Restart Claude Code, then ask "search for artist Lucinda Williams in Lidarr"
2. **Test slskd connection**: Check http://doc1:5030 shows "Connected" to Soulseek
3. **Test Soularr**: Add an album to Lidarr's wanted list, wait 5 min, check if Soularr triggers a search
4. **End-to-end**: Ask Claude "get me Whiskeytown Strangers Almanac" and watch it flow through

---

## Open Items

### Still To Determine

- [x] Exact path for music library: `/mnt/data/music/ai`
- [ ] Lidarr API key (will get after fresh config)
- [ ] Plex token (for MCP server if needed — may not be required if auto-scan works)
- [ ] Network: verify slskd can reach Soulseek network from doc1
- [x] Lidarr naming format preference: use defaults

### Notes

- Lidarr wasn't actually flakey — just never properly configured
- Music Assistant should automatically see new files via Plex (auto-scan enabled)
- Quality is overridable per request, 320kbps default

---

## Implementation Phases

### Phase 1: Infrastructure [CODE COMPLETE]
- [x] Docker compose for slskd
- [x] Docker compose for soularr
- [x] Firewall ports configured
- [ ] Deploy to doc1
- [ ] Configure Soulseek credentials (fill in sops placeholders)
- [ ] Test slskd web UI and API manually
- [ ] Verify network connectivity (Soulseek servers reachable)

### Phase 2: Lidarr Setup [PENDING]
- [ ] Fresh Lidarr configuration (nuke existing)
- [ ] Set root folder to `/mnt/data/music/ai`
- [ ] Configure import settings (tagging, naming)
- [ ] Get API key from Settings → General
- [ ] Test manual import of a downloaded album

### Phase 3: Bridge Setup [CODE COMPLETE]
- [x] Soularr container added to docker-compose
- [x] Soularr config template created
- [ ] Copy config to doc1 and add Lidarr API key
- [ ] Test: add album to Lidarr, verify Soularr picks it up

### Phase 4: MCP Integration [CODE COMPLETE]
- [x] Add mcp-arr-server to .mcp.json
- [x] Add Soulseek MCP to .mcp.json
- [x] MCP wrapper scripts created
- [x] NixOS module extended for arr/soulseek secrets
- [x] Sops secrets created (with placeholders)
- [ ] Fill in real credentials
- [ ] Test from Claude Code: search, download, import flow

### Phase 5: Polish [PENDING]
- [ ] Update CLAUDE.md with music automation workflow
- [ ] Add Plex library path if not present
- [ ] Optional: Gotify notifications on download complete
- [ ] Optional: Quality filters in Soularr/slskd config

---

## Example MCP Configuration

```json
{
  "mcpServers": {
    "arr": {
      "command": "npx",
      "args": ["-y", "mcp-arr-server"],
      "env": {
        "LIDARR_URL": "http://lidarr.local:8686",
        "LIDARR_API_KEY": "${LIDARR_API_KEY}"
      }
    },
    "soulseek": {
      "command": "node",
      "args": ["/path/to/SoulseekMCP/dist/index.js"],
      "env": {
        "SOULSEEK_USERNAME": "${SOULSEEK_USER}",
        "SOULSEEK_PASSWORD": "${SOULSEEK_PASS}",
        "DOWNLOAD_PATH": "/downloads/music"
      }
    },
    "plex": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-plex"],
      "env": {
        "PLEX_URL": "http://plex.local:32400",
        "PLEX_TOKEN": "${PLEX_TOKEN}"
      }
    }
  }
}
```

---

## Example Docker Compose Additions

```yaml
services:
  slskd:
    image: slskd/slskd:latest
    container_name: slskd
    environment:
      - SLSKD_REMOTE_CONFIGURATION=true
      - SLSKD_SHARED_DIR=/music
      - SLSKD_DOWNLOADS_DIR=/downloads
    volumes:
      - ./slskd/config:/app
      - /path/to/music:/music:ro      # Share with Soulseek network
      - /path/to/downloads:/downloads  # Download location
    ports:
      - "5030:5030"  # Web UI
      - "5031:5031"  # API
    restart: unless-stopped

  soularr:
    image: mrusse/soularr:latest
    container_name: soularr
    environment:
      - ANTHROPIC_API_KEY=not_needed   # Only if using AI features
    volumes:
      - ./soularr/config:/config
    depends_on:
      - slskd
    restart: unless-stopped
```

---

## Risk Considerations

1. **Soulseek availability**: Files may not be available, need graceful handling
2. **Quality inconsistency**: Different uploaders = different quality/tagging
3. **Legal considerations**: Soulseek operates in a gray area depending on jurisdiction
4. **Network stability**: Soulseek peers can disconnect mid-download
5. **Storage**: Music libraries grow; plan for capacity

---

## Next Steps

1. **Fill in Soulseek credentials** in `secrets/soulseek-mcp.env` and `secrets/music.env`
2. **Enable MCP module** in `hosts/proxmox-vm/configuration.nix` (see Remaining Manual Steps)
3. **Deploy to doc1**: `nixos-rebuild switch --flake .#proxmox-vm --target-host proxmox-vm`
4. **Fresh Lidarr setup** at http://doc1:8686, get API key
5. **Update Lidarr API key** in `secrets/arr-mcp.env` and soularr config on doc1
6. **Test the pipeline** end-to-end

---

## References

- [slskd GitHub](https://github.com/slskd/slskd)
- [slskd API Docs](https://github.com/slskd/slskd/blob/master/docs/api.md)
- [Soularr](https://soularr.net)
- [Soularr GitHub](https://github.com/mrusse/soularr)
- [SoulseekMCP](https://glama.ai/mcp/servers/@jotraynor/SoulseekMCP)
- [mcp-arr-server](https://www.npmjs.com/package/mcp-arr-server)
- [Lidarr](https://lidarr.audio/)
- [Lidarr API](https://lidarr.audio/docs/api/)
