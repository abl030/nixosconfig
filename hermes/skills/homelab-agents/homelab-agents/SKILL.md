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

- Firewall, DNS, DHCP, NAT, VPN, WireGuard, pfSense system config → load/use `pfsense`; terminal tool with `scripts/pfsense-api` (no MCP since #244).
- UniFi switches, APs, WLANs, VLAN-only networks, port profiles, clients → load/use `unifi`; terminal tool with `scripts/unifi-api` (no MCP since #244).
- Home Assistant entities, automations, dashboards, media playback → load/use `homeassistant`; use MCP toolset `mcp-homeassistant`.
- Grafana UI / browser dashboard verification → load/use `playwright`; use MCP toolset `mcp-playwright` once the wrapper is healthy.
- Radarr/Sonarr/Prowlarr/NZBHydra/qBittorrent/NZBGet → load/use `arr`; normal terminal/file tools.
- Unraid tower, Plex/tower containers, tower VMs/disks/shares → load/use `tower`; normal terminal/file tools.
- Audiobookshelf import/metadata/scan/library tasks → load/use `audiobookshelf`; normal terminal/file tools and ABS REST env on doc1/doc2.
- Mail archive search/reading → load/use `mailsearch` ONLY in human-present doc1 interactive sessions. Never expose to gateway/cron/webhooks/unattended agents.

For pfSense and UniFi, a one-off lookup needs no skill: run `scripts/pfsense-api` or
`scripts/unifi-api` directly. Load the skill (or delegate) for changes and for
investigations that read large collections.

## Hermes usage patterns

Direct session:

```sh
hermes --tui --skills homelab-agents,pfsense
```

Delegation from a parent Hermes session:

```text
delegate_task(goal="...", context="Load/follow the pfsense skill from nixosconfig Hermes external skills.")
```

Use `/agents` in the TUI to watch delegated subagents live.

## Safety

The migrated skills preserve the original Claude subagent safety rules. For destructive/disruptive operations, follow the skill-specific confirmation and blast-radius guidance before acting.
