# Subagent Context Buildout

## Done
- [x] pfSense — full network config documented in `.claude/agents/pfsense.md`, Mullvad cleaned up

## TODO
- [x] UniFi — query live config and populate `.claude/agents/unifi.md` with network topology, devices, WLANs, port profiles, VLANs
- [x] Home Assistant — live config queried and populated in `.claude/agents/homeassistant.md` (991 entities, 30 integrations, 42 automations, solar/battery/dental/zigbee); `home-assistant-best-practices` skill preloaded via plugin (flake input auto-updates)
- [x] **AUDIT: all subagents verified** — pfSense (187 lines) and UniFi (142 lines) pass full context check. HA rewritten to 67 lines (concise summaries + live query pointers). See docs/wiki/claude-code/skills-in-subagents.md.
- [ ] Loki — set up as subagent (currently removed from .mcp.json entirely, needs agent definition)
- [ ] Prometheus — set up as subagent (currently removed from .mcp.json entirely, needs agent definition)
