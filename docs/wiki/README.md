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
- [nfs-over-tailscale](infrastructure/nfs-over-tailscale.md) — Tailscale readiness gap, `tailscale-wait.service`, LAN-vs-tailnet routing for tower NFS
- [pfsense-dns-resolver](infrastructure/pfsense-dns-resolver.md) — pfSense as the fleet DNS resolver: tunables, restart commands, ntopng/pfBlockerNG/kea2unbound footguns
- [pfsense-backup](infrastructure/pfsense-backup.md) — ACB + ZFS-pull-to-prom + dual-Kopia off-site architecture, restore procedures incl. VM-on-prom emergency play
- [dns-saturation-incident-2026-05-22](infrastructure/dns-saturation-incident-2026-05-22.md) — RCA: chronic unbound TCP/53 saturation surfaced via `rolling-flake-update`; subagent → research debugging-loop pattern
- [pfblockerng-fastly-block-incident-2026-06-07](infrastructure/pfblockerng-fastly-block-incident-2026-06-07.md) — pfBlockerNG feed false-positive blocked cache.nixos.org's Fastly /16; misdiagnosed as ISP for hours; lesson: test from the firewall itself
- [nix-mirror-failover](infrastructure/nix-mirror-failover.md) — `nix-mirror.ablz.au` fails over cache.nixos.org → SJTU → TUNA; per-request re-resolution + `ipv6=off`; disk-caches the fallback once for the fleet
- [cratesio-403-ua](infrastructure/cratesio-403-ua.md) — crates.io 403s nix's `curl/` UA; resolved by nixpkgs static.crates.io fix (#259)
- [systemd-mount-ordering-cycles](infrastructure/systemd-mount-ordering-cycles.md) — why bind mounts on NFS need `_netdev`; cycle topology and latency-bomb properties

### Services

- [lgtm-stack](services/lgtm-stack.md) — Loki + Grafana + Tempo + Mimir on doc2
- [jellyfin](services/jellyfin.md) — native NixOS jellyfin on igpu, VAAPI transcoding, LAN + tailnet FQDNs
- [youtarr](services/youtarr.md) — Youtarr OCI app on doc2, MariaDB nspawn migration, image pinning
- [tdarr-node](services/tdarr-node.md) — tdarr worker node on igpu, OCI container with `/dev/dri`
- [amp-casting-automations](services/amp-casting-automations.md) — Home Assistant casting automations
- [rtrfm-nowplaying](services/rtrfm-nowplaying.md) — RTRFM "now playing" integration

### Claude Code

- [auto-memory-directory](claude-code/auto-memory-directory.md) — persistent memory layout
- [skills-in-subagents](claude-code/skills-in-subagents.md) — skill availability inside spawned subagents
- [playwright-subagent](claude-code/playwright-subagent.md) — headed/headless browser automation via CDP-attach Chrome
