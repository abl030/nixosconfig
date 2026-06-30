---
name: homelab-agents
description: Route homelab operations to the git-tracked Hermes skills migrated from nixosconfig/.claude/agents, and use the matching MCP toolsets when available.
version: 1.0.0
metadata:
  hermes:
    tags: [homelab, nixosconfig, routing, mcp, subagents]
---

# Homelab Agents Router

This skill is the Hermes-side routing layer for the Claude-style subagents tracked in `nixosconfig/.claude/agents` and mirrored as Hermes skills under `nixosconfig/hermes/skills/homelab-agents`.

## Routing

- Firewall, DNS, DHCP, NAT, VPN, WireGuard, pfSense system config → load/use `pfsense`; use MCP toolset `mcp-pfsense`.
- UniFi switches, APs, WLANs, VLAN-only networks, port profiles, clients → load/use `unifi`; use MCP toolset `mcp-unifi`.
- Home Assistant entities, automations, dashboards, media playback → load/use `homeassistant`; use MCP toolset `mcp-homeassistant`.
- Grafana UI / browser dashboard verification → load/use `playwright`; use MCP toolset `mcp-playwright` once the wrapper is healthy.
- Radarr/Sonarr/Prowlarr/NZBHydra/qBittorrent/NZBGet → load/use `arr`; normal terminal/file tools.
- Unraid tower, Plex/tower containers, tower VMs/disks/shares → load/use `tower`; normal terminal/file tools.
- Audiobookshelf import/metadata/scan/library tasks → load/use `audiobookshelf`; normal terminal/file tools and ABS REST env on doc1/doc2.
- Mail archive search/reading → load/use `mailsearch` ONLY in human-present doc1 interactive sessions. Never expose to gateway/cron/webhooks/unattended agents.

## Hermes usage patterns

Direct session:

```sh
hermes --tui --skills homelab-agents,pfsense --toolsets mcp-pfsense,skills,terminal,file
```

Delegation from a parent Hermes session:

```text
delegate_task(goal="...", context="Load/follow the pfsense skill from nixosconfig Hermes external skills.", toolsets=["mcp-pfsense", "terminal", "file"])
```

Use `/agents` in the TUI to watch delegated subagents live.

## Safety

The migrated skills preserve the original Claude subagent safety rules. For destructive/disruptive operations, follow the skill-specific confirmation and blast-radius guidance before acting.
