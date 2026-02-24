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

**CRITICAL**: Always use `vms/proxmox-ops.sh`, NEVER run Proxmox commands directly via SSH. Full workflow: `bd show nixosconfig-usj`.

## Secrets Management

Uses Sops-nix with Age encryption. Config: `secrets/.sops.yaml`. Full workflow: `bd show nixosconfig-mof`.

## Troubleshooting

- **`failed to insert entry: invalid object specified`** during `nix flake update`: Corrupted fetch cache. Fix with `rm -rf ~/.cache/nix/` and retry. This is safe — it's only a fetch cache, not the store. Common issue, happens periodically.

## Stabilization Rules

- Isolate assets/scripts/config sources with `builtins.path` or `writeTextFile` to avoid flake-source churn.
- Avoid relying on module import order for list options; use `lib.mkOrder` when order must be stable.

## Quality Gates

**`check --full` MUST pass before pushing.** Run `check` at feature boundaries — when a logical chunk of work is complete — not after every small change. `nix fmt` is cheap and fine to run anytime.

**Docs-only exception:** If a change only touches documentation files (for example `docs/**`, `README*`, `*.md`), skip `check` by default unless explicitly requested.

The `check` command runs a comprehensive quality gate that includes:
1. Format checking (Alejandra)
2. Linting (deadnix for unused code)
3. Linting (statix for style issues)
4. Flake checks (host config checks only with `check --full`)
5. Drift detection (only when invoked with `check --drift`)

```bash
# Run all checks before committing
check

# Include host config checks (slow)
check --full

# Only check specific host configs
check --hosts framework

# Include drift detection only when needed (slow)
check --drift

# If formatting issues are found
nix fmt

# The check command will exit with error if any check fails
```

### Known Eval Warnings (upstream, safe to ignore)

- `proxmox.qemuConf.diskSize` renamed to `virtualisation.diskSize` — upstream nixpkgs proxmox-image module sets a default using the old option name

## Hash-Based Drift Detection

Identical `system.build.toplevel` hashes guarantee identical systems. Use `check --drift` to compare against baselines. Full workflow: `bd show nixosconfig-bv0`.

## Gotify Notifications

If asked, send a Gotify ping before requesting human input and include a brief summary of what is needed.

## Debug Session Notes

Verify upstream with `--resolve` before changing nginx/Cloudflare. Full checklist: `bd show nixosconfig-2ie`.

## Standard Kuma Health Endpoints

Endpoint reference for monitoring setup: `bd show nixosconfig-2ws`.

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
- PRs should describe impact, commands run (`check`, `nix flake check`), and any deployment notes.

## Memory Discipline

**Beads are the primary memory system.** MEMORY.md (auto memory) is injected into every system prompt — keep it under 15 lines for critical technical patterns only.

| Use beads for | Use MEMORY.md for |
|---|---|
| Decisions and rationale | Shell/env quirks needed every session |
| Workflow preferences | "Never do X" safety rules |
| Research findings | One-liner pointers to beads |
| Feature progress | — |

When recording a decision: create/update a bead, optionally add a one-line pointer in MEMORY.md if it's referenced constantly. Do NOT duplicate rationale into MEMORY.md.

### Beads Per-Clone Setup

Beads uses a centralised Dolt server on doc1. All hosts connect over Tailscale.
See `modules/home-manager/services/claude-code.nix` for full architecture docs.

**Every fresh clone needs setup:**

```bash
# Point at doc1's centralised Dolt server
bd init --prefix nixosconfig \
  --server-host 100.89.160.60 \
  --server-port 3307 \
  --server-user beads
# Password is set automatically via BEADS_DOLT_PASSWORD env var

bd hooks install --force    # Installs pre-commit, post-merge, pre-push, post-checkout hooks
bd config set beads.role maintainer
bd migrate --update-repo-id  # Only if "LEGACY DATABASE" error appears
```

On doc1 itself, use `--server-host 127.0.0.1` instead.

Without hooks, JSONL won't be exported on commit — the hooks sync between Dolt and
the git-tracked `.beads/issues.jsonl` file automatically.

## AI Tool Integration

### MCP Servers

MCP servers are defined in `.mcp.json` (source of truth). Use `/sync-mcp` to push to Codex and `/add-mcp` to add new servers.

### Loki

The Loki MCP server queries logs from the homelab fleet. Usage notes:
- **Time formats**: Use RFC3339 (`2026-02-02T04:00:00Z`) or relative durations (`1h`, `30m`). Do NOT use `24h` or other durations as the `start` parameter — use an RFC3339 timestamp instead.
- Default query range is 1 hour. For longer ranges, compute the RFC3339 start time.
- Metric queries (`bytes_over_time`, `rate`, `count_over_time`) are not supported by the MCP tool — use log queries only.
- Hosts are labelled: `wsl`, `proxmox-vm` (doc1), `igpu`, `dev`, `cache`, `tower`.
- Container logs use the `container` label (e.g., `{host="proxmox-vm", container="immich-server"}`).
- **`rolling-flake-update.service`** runs on doc1 (`proxmox-vm`) nightly at 22:15 AWST (14:15 UTC). It is a systemd unit (NOT a GitHub Action). Query it with `unit="rolling-flake-update.service"` and `host="proxmox-vm"`. Use a start time before 14:15 UTC of the relevant day.

### Home Assistant

Tools are **deferred** — use `ToolSearch` with `+homeassistant` first. Full usage guide incl. Music Assistant playback and volume quirks: `bd show nixosconfig-fah`.

### Lidarr (Music Library)

Soularr handles download searching automatically. Do NOT manually search Soulseek, and do NOT call `lidarr_command_album_search` or any search trigger. The ONLY job is to get the album into Lidarr and set `monitored: true` — Soularr polls for monitored+missing albums and searches Soulseek on its own schedule. Triggering searches manually is wasted effort.

**Grabbing an album:**

1. **Web search first** — if you don't recognise the album, Google it. Don't guess or assume it doesn't exist.
2. **Try `lidarr_grab_album`** with artist name and album title.
3. **If the album isn't found**, it's likely too new for Lidarr's cached metadata:
   - Look up the MusicBrainz release group ID (search MusicBrainz API or web).
   - Use `lidarr_lookup_album` with `term=lidarr:<MBID>` to confirm it exists.
   - If the artist is already in Lidarr, run `lidarr_command_refresh_artist` to pull new metadata.
   - If the album STILL doesn't appear after refresh, check the artist's **metadata profile** — the album's secondary type (e.g., Soundtrack, Live) may be filtered out. Update the profile to allow it, then refresh again.
4. **Monitoring rules**:
   - The **artist** should be `monitored: true` with `monitorNewItems: "none"`.
   - Only the **requested album** should be `monitored: true`. Unmonitor any other albums that got auto-monitored.

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

See `bd show nixosconfig-usj` (VM ops) and `bd show nixosconfig-mof` (secrets).

## Fleet Overview

### Current Hosts

- **epimetheus**: Main workstation (desktop, full NixOS)
- **framework**: Laptop (Framework 13, full NixOS with hibernation)
- **caddy**: Server/container (Home Manager only)
- **wsl**: WSL instance (full NixOS with NixOS-WSL)
- **proxmox-vm** (doc1): Main services VM on Proxmox (VMID 104, imported)
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

### Container Stack Management

**Current Implementation:** All container stacks use `podman compose` (built-in podman subcommand wrapping docker-compose Go binary). This replaced the Python `podman-compose` wrapper in Feb 2025 for better reliability.

**Stack Architecture:**
- Stack definitions: `stacks/*/docker-compose.nix`
- Core library: `stacks/lib/podman-compose.nix`
- Configuration: `modules/nixos/homelab/containers/default.nix`

**Key Features:**
- Deploy path uses `podman compose up -d --remove-orphans` (no deploy-time `--wait` gating)
- API socket communication eliminates SQLite lock contention
- Single user service ownership (`${stackName}.service`) for stack lifecycle
- Native system-scope `sops.secrets` wiring for env files, with one-release legacy fallback support
- Hard-fail startup invariants (`PODMAN_SYSTEMD_UNIT` ownership + missing secret handling)

**Migration Gotchas (podman-compose → podman compose):**

1. **Network Label Mismatch** - OLD networks created by podman-compose lack `com.docker.compose.network` label that docker-compose requires. **Solution:** Remove old networks before first deployment:
   ```bash
   # List networks to remove
   podman network ls --format "{{.Name}}" | grep "_default$"

   # Remove unused networks (no containers attached)
   for net in $(podman network ls --format "{{.Name}}" | grep "_default$"); do
     containers=$(podman network inspect "$net" -f "{{len .Containers}}" 2>/dev/null || echo "0")
     if [ "$containers" -eq 0 ]; then
       podman network rm "$net"
     fi
   done
   ```

2. **Stale Container Reuse** - Docker-compose reuses existing containers if they match the config. If a container has a failed/stuck health check, docker-compose with `--wait` will wait forever for that stale health status to change. **Solution:** Remove containers with stuck health before redeploying:
   ```bash
   # Check for containers in perpetual "starting" state
   podman ps -a --format "table {{.Names}}\t{{.Status}}" | grep "starting"

   # Remove them to force fresh creation
   podman rm -f <container-name>
   ```
   This is **ongoing risk**, not just migration - can happen anytime a container gets into bad health state and isn't cleaned up before restart.

3. **Stricter YAML Parsing** - Docker-compose rejects duplicate mapping keys (podman-compose silently merged them). **Solution:** Fix YAML syntax errors:
   ```yaml
   # BAD (duplicate labels)
   labels:
     - io.containers.autoupdate=registry
   ...
   labels:
     - autoheal=true

   # GOOD (merged)
   labels:
     - io.containers.autoupdate=registry
     - autoheal=true
   ```

4. **Flag Compatibility** - `--in-pod` flag is podman-compose-specific and not recognized by docker-compose. Default behavior (no pod wrapping) is correct for docker-compose. **Solution:** Remove `--in-pod false` from stack definitions.

**IMPORTANT: Oneshot Service Behavior**
Container stacks use `Type=oneshot` with `restartIfChanged=true`. They only restart when config changes, NOT on every rebuild. If containers are manually removed (e.g., via `podman rm -f` or network cleanup), you must manually restart the services:
```bash
sudo runuser -u abl030 -- systemctl --user restart <stack-name>
```

**Migration verified on:** doc1 (proxmox-vm), igpu
**Remaining hosts:** None - all container hosts migrated

**Debugging Stuck Deployments:**
```bash
# Check what systemd is waiting on
systemctl list-jobs

# Check which services are stuck
systemctl list-units --state=activating

# Find the docker-compose process
ps aux | grep docker-compose

# Check container health status
podman inspect <container> --format '{{json .State.Health}}' | jq

# Kill stuck docker-compose and restart service
sudo kill <pid>
sudo runuser -u abl030 -- systemctl --user restart <stack-name>
```

## Important Files

- `flake.nix`: Entry point, defines outputs and imports
- `hosts.nix`: Single source of truth for fleet identity
- `nix/lib.nix`: Configuration factory functions
- `modules/nixos/profiles/base.nix`: Base profile for all NixOS hosts
- `vms/definitions.nix`: VM specifications and inventory
- `vms/proxmox-ops.sh`: Safe Proxmox operations wrapper
- `secrets/.sops.yaml`: Age key configuration for secrets

## Special Configurations

Host-specific details for doc1, igpu, and framework: `bd show nixosconfig-6bn`.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

<!-- END BEADS INTEGRATION -->
