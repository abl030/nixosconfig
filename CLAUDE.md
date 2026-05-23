# !! CRITICAL: CHECK HOSTNAME BEFORE REBUILD !!
#
# BEFORE running `nixos-rebuild switch`, ALWAYS run `hostname` first.
# Use the ACTUAL hostname in the flake URI: --flake .#<actual-hostname>
# NEVER assume which host you are on. NEVER hardcode a hostname.
# Getting this wrong rebuilds the WRONG system config onto the current machine.
#

# !! CRITICAL: NEVER REBUILD FROM A STALE LOCAL CHECKOUT !!
#
# Every fleet host runs `rolling-flake-update.service` nightly — it bumps
# `flake.lock` to tip AND deploys against `github:abl030/nixosconfig`. So
# every host's currently-running closure is pinned to "tip of master at
# 22:15 AWST last night" with a HOT binary cache for those store paths.
#
# If you rebuild from a local checkout that is behind origin/master, you
# will:
#   1. Resolve an OLDER flake.lock → downgrade the entire world (kernel,
#      systemd, every package).
#   2. Miss the warm cache — every downgraded store path is re-downloaded
#      from upstream, not our mirror.
#   3. Potentially destabilise things that depend on newer upstream fixes.
#
# Before ANY `nixos-rebuild switch` on a fleet host, check:
#   git fetch && git status -sb
# If the local branch is behind origin/master, do ONE of:
#   a) Rebase/fast-forward to tip, re-apply your in-progress changes:
#        git stash && git pull --rebase && git stash pop
#   b) Build from the GitHub flake directly (skip the local tree entirely):
#        sudo nixos-rebuild switch --flake github:abl030/nixosconfig#<host> --refresh
#      Use this when you have NO local changes to apply.
#
# NEVER `nixos-rebuild switch --flake .#<host>` while the working tree is
# behind origin. The 5–10 minute "fast" rebuild you expected becomes a
# multi-gigabyte re-fetch of a downgraded world.
#

# !! INTERACTION STYLE !!
#
# DO NOT use AskUserQuestion / the structured question UI. The user dislikes
# it — just chat in plain text. Present decisions as a conversational message
# and let them reply normally.
#
# When there are multiple decisions to make, present them ONE AT A TIME and
# wait for an answer before moving to the next. Only bundle questions when
# they are very small or tightly linked.
#

# !! CRITICAL: NEVER DEPLOY REMOTELY WITH --target-host !!
#
# To deploy to a remote host (doc1/doc2/igpu/etc.):
#   1. `git push` first — the host pulls from GitHub.
#   2. `ssh <host> "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#<hostname> --refresh"`
#
# --refresh forces Nix to re-resolve the flake ref so the latest push is picked up.
# The remote host builds locally from the GitHub checkout — nothing transits
# your laptop or the SSH connection. This is the ONLY pattern that works
# reliably over Tailscale / VPN / slow links.
#
# NEVER use `nixos-rebuild switch --flake .#<host> --target-host <host>`. That
# mode builds the closure on THIS machine and pushes it over SSH — slow, burns
# bandwidth, breaks on flaky links, and leaves uncommitted local work in the
# built closure. The service-deploy skill has a full runbook; always follow it.
#

# !! CRITICAL: NEVER `nix build` ON WSL !!
#
# When `hostname` reports `wsl`, do NOT run `nix build .#nixosConfigurations.<host>...`
# to validate a remote-host change. WSL pulls the full closure (tens of GB) from
# the binary cache over a slow link — it will hang or burn bandwidth for nothing,
# and the build artefact isn't used anywhere (the remote host rebuilds from
# GitHub via the deploy pattern above).
#
# To validate a change for a remote host from WSL:
#   - `nix flake check` (eval-only, no closure fetch) for syntax/type errors, OR
#   - push and let the remote host build it during `nixos-rebuild switch --refresh`.
#

# !! SESSION START: ALWAYS RUN THESE FIRST !!
#
# At the START of every conversation, run `hostname` and `date` before doing
# anything else. This establishes which machine you are on and the current time.
# Do this silently — no need to announce it, just know your context.
#

# !! CRITICAL: AUDIT FOR LEAST PRIVILEGE !!
#
# This repo is moving to least-privilege bit by bit. Anything you add or
# touch — modules, scripts, configs, deploy steps — gets a privilege and
# blast-radius audit before commit. Two threat models, both assumed:
# external probe (LAN, internet, Tailscale) and post-compromise lateral
# movement (upstream supply chain, evil maid, one container popped).
#
# The blast radius of a single failure must stay bounded. If a change
# touches auth, secrets, image trust, network exposure, file ownership,
# or shared resources — flag it, don't paper over it.
#
# Concrete patterns / anti-patterns / checklist live in
# `docs/wiki/nixos-service-modules.md`. Outstanding work is tracked
# in issue #232; new findings get appended there.
#

# !! NO SCOPE-SPLITTING TO DEFER WORK !!
#
# When an issue or task contains multiple related items, tackle ALL of
# them in one session. Do NOT propose splitting items out into
# follow-up issues "for later" — follow-ups accumulate, never get
# prioritised, and the original work stays half-finished forever.
#
# Force a decision on every item in scope, even if some parts will
# land in multiple PRs over a few days. "Different shape of work" or
# "outside the module" is not a reason to defer — it's a reason to
# brainstorm harder. Genuinely blocked items get an explicit blocker
# named in the issue, not a sibling-issue dump.
#

# !! CRITICAL: DO THE MIGRATION, DON'T CODE A DEFERRAL MACHINE !!
#
# When the real task is a data/service migration, perform the migration during
# the work session. Do NOT replace it with runtime cutover guards, approval
# JSON, rollback state machines, or "operator must later..." paths unless the
# user explicitly asks to stage instead of migrate.
#
# Safety belongs in preflight checks, backups when needed, verification, and a
# clear rollback command — not in permanent code that exists only because the
# migration was deferred. If the system is already live and verified, remove
# migration scaffolding before calling the work complete.
#

# Repository Guidelines

This file provides guidance to AI coding assistants working with this repository.
It is the single source of truth for both Claude Code (CLAUDE.md) and Codex (AGENTS.md via symlink).

## Repository Overview

This is a flake-based NixOS and Home Manager configuration managing a homelab infrastructure. The repository uses a custom configuration factory pattern to generate both full NixOS systems and standalone Home Manager configurations from a single host definition file (`hosts.nix`).

## Core Architecture

### Configuration Factory Pattern

The heart of this repo is `nix/lib.nix`, which provides two factory functions:
- `mkNixosSystem`: Creates full NixOS configurations (machines with `configurationFile` in `hosts.nix`)
- `mkHomeConfiguration`: Creates standalone Home Manager configs (machines without `configurationFile`)

Both functions automatically inject:
- Standard module sets (NixOS, Home Manager, Sops)
- Special arguments: `inputs`, `hostname`, `allHosts`, `system`, `flake-root`, `hostConfig`
- Global overlays and registry settings

### Host Definition System

`hosts.nix` is the **single source of truth** for fleet identity and trust. Each host entry defines:
- **Identity**: hostname, sshAlias, user, homeDirectory
- **Trust**: publicKey (SSH host key), authorizedKeys (who can access)
- **Config**: paths to configuration.nix and home.nix files
- Optional: initialHashedPassword, sudoPasswordless

The presence of `configurationFile` determines whether a host is a full NixOS system or Home Manager-only.

### Module Structure

**NixOS modules** (`modules/nixos/`):
- `profiles/base.nix`: Base profile automatically imported for all NixOS hosts
- Custom modules under `homelab.*` namespace:
  - `homelab.ssh`: SSH server configuration
  - `homelab.tailscale`: Tailscale mesh networking
  - `homelab.update`: Automated system updates and garbage collection
  - `homelab.nixCaches`: Nix cache client configuration
  - `homelab.cache`: Nix cache server (for doc1)
  - `homelab.ci`: CI/CD including GitHub Actions runners and rolling flake updates

**Home Manager modules** (`modules/home-manager/`):
- Registered in `modules/home-manager/default.nix`
- Display, shell, services, and multimedia configurations
- Automatically imported for both NixOS (via HM module) and standalone HM configs

## Secrets Management

Uses Sops-nix with Age encryption. Config: `secrets/.sops.yaml`.

## Troubleshooting

- **`failed to insert entry: invalid object specified`** during `nix flake update`: Corrupted fetch cache. Fix with `rm -rf ~/.cache/nix/` and retry. This is safe — it's only a fetch cache, not the store. Common issue, happens periodically.

## Issue and TODO Tracking

- Larger work items are tracked in **GitHub issues** on this repo. Use `gh issue list`, `gh issue view <n>`, and `gh issue create` for everything agent-facing.
- Lightweight in-repo TODOs live in `docs/todo/*.md`. Check there before starting new work.
- Historical issues from the retired `bd` (beads) tracker are archived in `docs/beads-archive.md` — read-only reference, do not try to resurrect the `.beads/` directory.

## Wiki / Knowledge Base

`docs/wiki/` is our internal knowledge base — written **by AI agents, for AI agents**. It captures research findings, architectural decisions, upstream bugs, workarounds, and operational knowledge that doesn't belong in code comments or CLAUDE.md.

**Structure:**
- `docs/wiki/claude-code/` — Claude Code features, plugins, skills, bugs, workarounds
- `docs/wiki/infrastructure/` — Network, VMs, storage, monitoring
- `docs/wiki/services/` — Container stacks, integrations, service-specific docs

**For external agents** (paperless, accounting/beancount from `git.ablz.au/abl030/agents`): start at [`docs/wiki/agent-operations.md`](docs/wiki/agent-operations.md) — service module map, edit/deploy workflow, secrets layout.

**Rules:**
- Update the wiki as you go. When you research something, document it.
- In modules, agents, and config files, add comment pointers to relevant wiki docs (e.g. `# See docs/wiki/claude-code/skills-in-subagents.md`). This creates a breadcrumb trail so future sessions can find context fast.
- Wiki docs should include: date researched, status (working/broken/upstream bug), issue links, what we tried, what works, and when to revisit.
- Don't duplicate CLAUDE.md content into the wiki — CLAUDE.md is for rules and instructions, the wiki is for research and rationale.

## Stabilization Rules

- Isolate assets/scripts/config sources with `builtins.path` or `writeTextFile` to avoid flake-source churn.
- Avoid relying on module import order for list options; use `lib.mkOrder` when order must be stable.

### Known Eval Warnings (upstream, safe to ignore)

- `proxmox.qemuConf.diskSize` renamed to `virtualisation.diskSize` — upstream nixpkgs proxmox-image module sets a default using the old option name

## Gotify Notifications

If asked, send a Gotify ping before requesting human input and include a brief summary of what is needed.

## Debug Session Notes

Verify upstream with `--resolve` before changing nginx/Cloudflare.

## Standard Kuma Health Endpoints

Monitor URL conventions and defaults are documented inline in `modules/nixos/services/uptime-kuma.nix` and per-service modules under `modules/nixos/services/`.

## Coding Style

- Nix formatting is enforced via Alejandra (`nix fmt`); let the formatter decide layout.
- Run deadnix for unused declarations and statix for style/lint issues.
- Prefer explicit, descriptive module names under `modules/nixos/` and `modules/home-manager/`.
- Keep host names consistent with `hosts.nix` and `hosts/<name>/`.
- If adding scripts, ensure shellcheck warnings are addressed or justified.
- There is no separate unit test suite; validation is via `nix flake check`.

## Commit & PR Guidelines

- Follow Conventional Commits style like `fix(pve): ...`; keep messages short and scoped.
- If a change is operational or host-specific, mention the host, module, or subsystem in the subject.
- PRs should describe impact and any deployment notes.

## Memory Discipline

MEMORY.md (auto memory) is injected into every system prompt — keep it under 15 lines for critical technical patterns only.

- Use **GitHub issues** for decisions, rationale, workflow preferences, research findings, and feature progress.
- Use **MEMORY.md** for shell/env quirks needed every session, "never do X" safety rules, and one-line pointers to relevant GitHub issues.
- The `docs/wiki/` tree is the long-form knowledge base for research and architectural context.

Do NOT duplicate rationale into MEMORY.md — point to the issue or wiki page instead.

## AI Tool Integration

### MCP Servers

MCP servers are defined in `.mcp.json` (source of truth). Use `/add-mcp` to add new servers.

### Loki / LGTM stack

Logs, metrics, and traces live on **doc2** (LGTM: Loki + Grafana + Tempo + Mimir). See `docs/wiki/services/lgtm-stack.md` for architecture, gotchas, and migration history.

Agent-facing query paths:
- **Grafana Explore:** https://logs.ablz.au — interactive log/metric browsing.
- **Loki HTTP API:** `https://loki.ablz.au/loki/api/v1/query_range?query={host="<h>"}&start=<RFC3339-or-ns>&end=<…>&limit=<n>`.
- **Label values:** `curl -s https://loki.ablz.au/loki/api/v1/label/host/values | jq .data` → returns the current ingesting hosts.

Usage notes:
- **Time formats**: Use RFC3339 (`2026-02-02T04:00:00Z`) in queries. Loki also accepts nanosecond epochs.
- Default query range is 1 hour; compute a start timestamp for longer windows.
- Current `host` labels: `doc2`, `igpu`, `proxmox-vm` (doc1), `framework`, `epimetheus`, `wsl`, `cache`, `dev`, `tower` (Unraid), `pfsense` (via syslog).
- Container logs use the `container` label (e.g. `{host="proxmox-vm", container="immich-server"}`).
- **`rolling-flake-update.service`** runs on doc1 (`proxmox-vm`) nightly at 22:15 AWST (14:15 UTC). It is a systemd unit (NOT a GitHub Action). Query with `{unit="rolling-flake-update.service", host="proxmox-vm"}` using an RFC3339 `start` before 14:15 UTC of the relevant day.
- The former `loki-mcp` server was removed in April 2026 — query Loki directly via HTTP or Grafana.

### Home Assistant, pfSense, UniFi

These MCPs are **subagent-only** — defined in `.claude/agents/` to avoid context bloat. Spawn the appropriate agent when you need to interact with them:
- `homeassistant` — Home automation, entities, automations, media playback
- `pfsense` — Firewall rules, NAT, VPN, DHCP, DNS
- `unifi` — Network devices, clients, WLANs, port profiles

Full HA usage guide incl. Music Assistant playback and volume quirks lives in `docs/wiki/services/` (search for `home-assistant`).

### mcp-nixos

[mcp-nixos](https://github.com/utensils/mcp-nixos) prevents hallucinations about NixOS:
- Provides real-time access to 130K+ packages and 22K+ NixOS options
- Validates package names and option paths against official APIs
- Eliminates guesswork about deprecated options or renamed packages

## Fleet Overview

### Current Hosts

- **epimetheus**: Main workstation (desktop, full NixOS)
- **framework**: Laptop (Framework 13, full NixOS with hibernation)
- **caddy**: Server/container (Home Manager only)
- **wsl**: WSL instance (full NixOS with NixOS-WSL)
- **proxmox-vm** (doc1): Main services VM on Proxmox prom
- **doc2**: Secondary services VM on Proxmox prom (IPs: 192.168.1.35/ens18, 192.168.1.36/ens19). Hosts most homelab services: immich, seerr/overseerr, cratedigger, slskd, musicbrainz, discogs, paperless, mealie, kopia, uptime-kuma, etc. All state on virtiofs (`device = "containers"` from prom ZFS). Auto-updates with reboot.
- **igpu**: Media transcoding VM on Proxmox prom with AMD iGPU passthrough
- **dev**: Development VM on Proxmox prom

### Hypervisors

- **prom** (192.168.1.12, AMD 9950X): Proxmox host running most VMs (doc1, doc2, igpu, dev, …). Manage via the Proxmox web UI; no in-repo automation.
- **tower** (192.168.1.2): Unraid host running NAS + some VMs + docker stacks. `ssh root@tower` works but is gated — ask the user to unlock first.

### Network & DNS Topology (non-obvious — read before debugging)

- **`192.168.1.1` and `100.123.61.111` are the same box: pfSense.** LAN interface and Tailscale interface. Logs that mention both are not describing two failures.
- **pfSense's unbound is the single recursive DNS resolver for the entire fleet.** Every NixOS host's `tailscaled` forwards DNS upstream to pfSense; pfSense forwards out to Cloudflare DoT (`1.1.1.2`/`1.0.0.2`). If pfSense unbound stops, the whole fleet loses non-MagicDNS resolution.
- **`tailscaled` uses TCP/53 for forwarded queries in this environment** (empirical, despite public Tailscale docs suggesting UDP-only). Each NixOS host holds ~4 persistent ESTABLISHED TCP/53 connections to pfSense at idle. Check with `sudo ss -tnp '( dport = :53 )'` on any fleet host.
- **ntopng runs on pfSense, NOT on doc2.** doc2 only runs the Go `ntopng-exporter` (HTTP scraper, no DNS). ntopng tuning (e.g. `--dns-mode`) is pfSense-side.
- **pfSense logs ship to doc2 Loki** as of 2026-05-23: `{host="pfsense", app=<program>}` — observed apps include `unbound`, `kea2unbound`, `filterlog`, `filterdns`, `nginx`, `kea-dhcp4`, `kernel`, `php`, `syslogd`. pfBlockerNG DNSBL blocks come through as `app="unbound"` with `[pfBlockerNG]` prefix.
- See [docs/wiki/infrastructure/pfsense-dns-resolver.md](docs/wiki/infrastructure/pfsense-dns-resolver.md) for tunables, restart commands, and footguns (kea2unbound reload-per-lease, ntopng restart-script gotcha, pfBlockerNG `dnsbl_python` mode, `serve-expired` RFC 8767 setup). Past incident: [docs/wiki/infrastructure/dns-saturation-incident-2026-05-22.md](docs/wiki/infrastructure/dns-saturation-incident-2026-05-22.md).

## Containers

The rootless `podman compose` stack system was retired on 2026-04-16 — every stack became a native NixOS module under `modules/nixos/services/`. For service-adjacent containers that remain (tdarr-node, youtarr, netboot, jdownloader2, the tailscale-share sidecars), use:

- **`virtualisation.oci-containers.containers.<name>`** — standard nixpkgs OCI wrapper, driven by `homelab.podman` (rootful) for autoupdate + autoheal.
- **`modules/nixos/services/tailscale-share.nix`** — per-service inter-tailnet pinhole pattern (ts sidecar + caddy sidecar, each a dedicated tailnet node).
- **`modules/nixos/lib/mk-pg-container.nix`** — isolated PostgreSQL via systemd-nspawn when a service needs its own DB.

See `docs/wiki/services/retired-container-stacks.md` for what was retired and how to recover a stack from git history if needed. See `docs/wiki/nixos-service-modules.md` for the service hierarchy (upstream module > custom module > OCI container).

## Special Configurations

Host-specific details for doc1, igpu, and framework live in their respective `hosts/<name>/configuration.nix` and `hosts/<name>/home.nix` files.

## Session Completion

When work is committed, push it. `git pull --rebase && git push` is pre-authorised in this repo — don't ask, don't leave commits stranded locally, don't say "ready to push when you are". If push fails, resolve and retry.

## Issue Tracking

GitHub issues (`gh`) cover both real bugs/features and long-running session work that spans multiple conversations. Historical beads issues are read-only in `docs/beads-archive.md`.
