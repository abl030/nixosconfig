# !! CRITICAL: CHECK HOSTNAME BEFORE REBUILD !!
#
# BEFORE running `nixos-rebuild switch`, ALWAYS run `hostname` first.
# Use the ACTUAL hostname in the flake URI: --flake .#<actual-hostname>
# NEVER assume which host you are on. NEVER hardcode a hostname.
# Getting this wrong rebuilds the WRONG system config onto the current machine.
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

# !! SESSION START: ALWAYS RUN THESE FIRST !!
#
# At the START of every conversation, run `hostname` and `date` before doing
# anything else. This establishes which machine you are on and the current time.
# Do this silently — no need to announce it, just know your context.
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

## VM Automation

**CRITICAL**: Always use `vms/proxmox-ops.sh`, NEVER run Proxmox commands directly via SSH.

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

## Common Commands

### Building and Deploying

```bash
# Build configuration
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel

# Deploy to local machine
sudo nixos-rebuild switch --flake .#<hostname>

# Deploy to remote machine
nixos-rebuild switch --flake .#<hostname> --target-host <hostname>

# Build from GitHub (no local checkout needed)
nixos-rebuild switch --flake github:abl030/nixosconfig#<hostname>

# Test configuration without switching
nix flake check

# Show what would change
nixos-rebuild build --flake .#<hostname>
nix run nixpkgs#nvd -- diff /run/current-system ./result
```

### Development Tools

```bash
# Format all Nix files
nix fmt

# Check formatting without writing
nix run .#fmt-nix -- --check

# Show formatting diffs
nix run .#fmt-nix -- --diff

# Lint with deadnix + statix
nix run .#lint-nix

# Enter dev shell
nix develop
```

### VM Operations & Secrets

See `vms/proxmox-ops.sh` (VM ops) and `secrets/.sops.yaml` (secrets). Longer-form notes live in `docs/wiki/infrastructure/`.

## Fleet Overview

### Current Hosts

- **epimetheus**: Main workstation (desktop, full NixOS)
- **framework**: Laptop (Framework 13, full NixOS with hibernation)
- **caddy**: Server/container (Home Manager only)
- **wsl**: WSL instance (full NixOS with NixOS-WSL)
- **proxmox-vm** (doc1): Main services VM on Proxmox (VMID 104, imported)
- **doc2**: Secondary services VM on Proxmox (IPs: 192.168.1.35/ens18, 192.168.1.36/ens19). Hosts most homelab services: immich, seerr/overseerr, cratedigger, lidarr, musicbrainz, paperless, mealie, kopia, uptime-kuma, etc. All state on virtiofs (`device = "containers"` from prom ZFS). Auto-updates with reboot.
- **igpu**: Media transcoding with AMD iGPU passthrough (VMID 109, imported)
- **dev**: Development VM (VMID 110, managed)

### Proxmox Infrastructure

- **Primary Host**: prom (192.168.1.12) - AMD 9950X with iGPU
- **Default Storage**: nvmeprom (ZFS pool, 3.53 TB available)
- **VMID Ranges**:
  - 100-199: Production VMs
  - 200-299: LXC containers
  - 9000-9999: Templates

## Key Design Patterns

### Base Profile Application

Every NixOS host automatically gets `modules/nixos/profiles/base.nix` which:
- Sets hostname from `hostConfig.hostname`
- Configures locales (Australia/Perth, en_GB)
- Enables flakes and auto-optimise-store
- Enables `homelab.*` defaults (SSH, Tailscale, updates, nix caches)
- Creates user from `hostConfig.user` with authorized keys
- Adds standard packages (git, vim, wget, home-manager, nvd)
- Shows nvd diff on system activation

All settings use `lib.mkDefault` so individual hosts can override.

### Special Arguments Available in Modules

- `inputs`: All flake inputs (nixpkgs, home-manager, sops-nix, etc.)
- `hostname`: Current host's name (from hosts.nix key)
- `hostConfig`: Full host definition from hosts.nix
- `allHosts`: All hosts from hosts.nix (for cross-host reference)
- `flake-root`: The flake root (self)
- `system`: "x86_64-linux"

### Containers

The rootless `podman compose` stack system was retired on 2026-04-16 — every stack became a native NixOS module under `modules/nixos/services/`. For service-adjacent containers that remain (tdarr-node, youtarr, netboot, jdownloader2, the tailscale-share sidecars), use:

- **`virtualisation.oci-containers.containers.<name>`** — standard nixpkgs OCI wrapper, driven by `homelab.podman` (rootful) for autoupdate + autoheal.
- **`modules/nixos/services/tailscale-share.nix`** — per-service inter-tailnet pinhole pattern (ts sidecar + caddy sidecar, each a dedicated tailnet node).
- **`modules/nixos/lib/mk-pg-container.nix`** — isolated PostgreSQL via systemd-nspawn when a service needs its own DB.

See `docs/wiki/services/retired-container-stacks.md` for what was retired and how to recover a stack from git history if needed. See `.claude/rules/nixos-service-modules.md` for the service hierarchy (upstream module > custom module > OCI container).

## Important Files

- `flake.nix`: Entry point, defines outputs and imports
- `hosts.nix`: Single source of truth for fleet identity
- `nix/lib.nix`: Configuration factory functions
- `modules/nixos/profiles/base.nix`: Base profile for all NixOS hosts
- `vms/definitions.nix`: VM specifications and inventory
- `vms/proxmox-ops.sh`: Safe Proxmox operations wrapper
- `secrets/.sops.yaml`: Age key configuration for secrets

## Special Configurations

Host-specific details for doc1, igpu, and framework live in their respective `hosts/<name>/configuration.nix` and `hosts/<name>/home.nix` files.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create GitHub issues (`gh issue create`) for anything that needs follow-up.
2. **Update issue status** - Close finished work, update in-progress items via `gh issue close` / `gh issue comment`.
3. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
4. **Clean up** - Clear stashes, prune remote branches
5. **Verify** - All changes committed AND pushed
6. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

## Issue Tracking with GitHub Issues

Use **GitHub issues** (via `gh`) for all non-trivial task tracking. Lightweight TODOs go in `docs/todo/*.md`.

### Quick reference

```bash
gh issue list --state=open              # See open issues
gh issue list --search="label:bug"      # Filter by label
gh issue view <n>                       # View issue details
gh issue create --title "..." --body "..." --label bug,priority:high
gh issue close <n> --reason completed --comment "Shipped in <commit>"
gh issue comment <n> --body "..."       # Add a comment
```

### Suggested labels

Apply labels per issue as appropriate:

- **Type**: `bug`, `feature`, `task`, `chore`, `epic`
- **Priority**: `priority:critical`, `priority:high`, `priority:medium`, `priority:low`
- **Area**: `area:nix`, `area:containers`, `area:monitoring`, `area:vm`, etc.

### Workflow for AI agents

1. **Check open work**: `gh issue list --state=open --assignee=@me` (or no assignee for grab-bag).
2. **Claim a task**: `gh issue edit <n> --add-assignee @me` and drop a starter comment.
3. **Work on it**: Implement, test, document.
4. **Discover new work?** `gh issue create` and, if related, link it in a comment on the parent (`Related to #<n>`).
5. **Complete**: Commit with `Closes #<n>` in the message, or close explicitly with `gh issue close <n>`.

Historical issues from the retired beads tracker are read-only in `docs/beads-archive.md`.
