# Hermes configuration tracked from nixosconfig

This directory holds the git-tracked Hermes pieces for the doc1/default profile integration.

## What is tracked

- `config/default/config.yaml` — the default-profile Hermes config used on doc1. It contains no API tokens; secrets remain in `~/.hermes/.env`, `~/.hermes/auth.json`, and `/run/secrets/...`.
- `skills/homelab-agents/*/SKILL.md` — Hermes skills migrated from `.claude/agents/*.md` so the Claude-style homelab subagents are visible to Hermes and tracked in git.

## Live symlink

On doc1, `~/.hermes/config.yaml` is symlinked to:

```text
/home/abl030/nixosconfig/hermes/config/default/config.yaml
```

So future `hermes config ...`, `hermes mcp ...`, and skill-dir changes that edit config will appear as a normal git diff in this repo.

## MCP layout

The config declares MCP servers using the existing repo wrappers:

- `nixos` → `uvx mcp-nixos` (small/default CLI toolset `mcp-nixos`)
- `pfsense` → `scripts/mcp-pfsense.sh` (`mcp-pfsense`, opt-in)
- `unifi` → `scripts/mcp-unifi.sh` (`mcp-unifi`, opt-in)
- `homeassistant` → `scripts/mcp-homeassistant.sh` (`mcp-homeassistant`, opt-in)
- `playwright` → `scripts/mcp-playwright.sh` (`mcp-playwright`, opt-in)
- `mailsearch` → `scripts/mcp-mailsearch.sh` configured but disabled; enable only for human-present doc1 sessions, never always-on/gateway/cron.

## Common usage

```sh
# TUI with live subagent tree
hermes --tui

# Direct pfSense-focused session
hermes --tui --skills homelab-agents,pfsense --toolsets mcp-pfsense,skills,terminal,file

# Direct UniFi-focused session
hermes --tui --skills homelab-agents,unifi --toolsets mcp-unifi,skills,terminal,file

# Direct Home Assistant-focused session
hermes --tui --skills homelab-agents,homeassistant --toolsets mcp-homeassistant,skills,terminal,file
```

In the TUI, use `/agents` to watch delegated subagents live.

## Verification

```sh
hermes skills list | grep homelab-agents
hermes mcp list
hermes mcp test nixos
hermes mcp test pfsense
hermes mcp test unifi
hermes mcp test homeassistant
hermes mcp test playwright
```
