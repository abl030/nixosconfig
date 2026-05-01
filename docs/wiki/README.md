# Wiki

Internal knowledge base for research findings, architectural decisions, and operational knowledge that doesn't belong in code comments or CLAUDE.md.

## Structure

- `claude-code/` — Claude Code features, plugins, skills, bugs, workarounds
- `infrastructure/` — Network, VMs, storage, monitoring
- `services/` — Container stacks, integrations, service-specific docs

## Index

### Top-level

- [agent-operations](agent-operations.md) — primer for external agents (paperless, accounting/beancount): module map, edit/deploy workflow, secrets layout

### Infrastructure

- [igpu-passthrough](infrastructure/igpu-passthrough.md) — AMD iGPU → `igpu` VM, `/dev/dri` health, kernel-reboot footgun
- [media-filesystem](infrastructure/media-filesystem.md) — mergerfs + virtiofs + tower NFS layout, where each library's media/metadata lives

### Services

- [lgtm-stack](services/lgtm-stack.md) — Loki + Grafana + Tempo + Mimir on doc2
- [jellyfin](services/jellyfin.md) — native NixOS jellyfin on igpu, VAAPI transcoding, LAN + tailnet FQDNs
- [tdarr-node](services/tdarr-node.md) — tdarr worker node on igpu, OCI container with `/dev/dri`
- [amp-casting-automations](services/amp-casting-automations.md) — Home Assistant casting automations
- [rtrfm-nowplaying](services/rtrfm-nowplaying.md) — RTRFM "now playing" integration

### Claude Code

- [auto-memory-directory](claude-code/auto-memory-directory.md) — persistent memory layout
- [skills-in-subagents](claude-code/skills-in-subagents.md) — skill availability inside spawned subagents
- [playwright-subagent](claude-code/playwright-subagent.md) — headed/headless browser automation via CDP-attach Chrome
