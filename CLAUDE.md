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

## Stabilization Rules

- Isolate assets/scripts/config sources with `builtins.path` or `writeTextFile` to avoid flake-source churn.
- Avoid relying on module import order for list options; use `lib.mkOrder` when order must be stable.

## Quality Gates

**`check --full` MUST pass before pushing.** Run `check` at feature boundaries — when a logical chunk of work is complete — not after every small change. `nix fmt` is cheap and fine to run anytime.

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

Beads git hooks live in `.git/hooks/` (local, not tracked by git). **Every fresh clone needs setup:**

```bash
bd hooks install          # Installs pre-commit, post-merge, pre-push, post-checkout hooks
bd config set beads.role maintainer
bd migrate --update-repo-id  # Only if "LEGACY DATABASE" error appears
```

Without hooks, `bd sync` must be run manually — beads created without syncing exist only in the local SQLite DB and will be lost if the clone is deleted. The hooks automate `bd sync` on commit/push so this can't happen silently.

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

### Home Assistant

Tools are **deferred** — use `ToolSearch` with `+homeassistant` first. Full usage guide incl. Music Assistant playback and volume quirks: `bd show nixosconfig-fah`.

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
- `--wait` flag blocks until containers pass health checks or fail
- Proper error propagation (nonzero exit codes)
- API socket communication eliminates SQLite lock contention
- Dual service architecture: system service (main) + user service (auto-update)

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

**Deploying to New Hosts (e.g., igpu):**
1. Network cleanup will be needed (same as doc1 migration)
2. Expect stale container issues on first deploy - remove them and redeploy
3. Check for duplicate YAML keys with: `docker-compose -f <file> config` (validates syntax)
4. Monitor first startup for health check timeouts

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
sudo systemctl restart <stack-name>
```

**Rebuild vs Auto-Update Behavior** (Research: `docs/research/container-lifecycle-analysis.md`)

**Decision (2026-02-12):** Keep current dual service architecture with targeted stale health detection.

**Key Findings:**

1. **Container reuse DOES cause stale health checks** - confirmed, real production issue
2. **Different scenarios already use different strategies** - dual services are correct by design
3. **User services already recreate containers** - systemd ExecStop → ExecStart cycle provides Watchtower-style fresh deployment
4. **Solution: Detect and remove stale containers before reuse** - fix root cause, not blanket workaround

**Dual Service Architecture (Confirmed Correct):**

```
System Service (<stack>-stack.service):
  Triggered by: nixos-rebuild switch
  Purpose: Apply config changes incrementally
  Strategy: Smart reuse (fast, only restart changed containers)
  Current: docker-compose up -d --wait --remove-orphans
  Protection: Will add stale health detection (see below)

User Service (podman-compose@<project>.service):
  Triggered by: podman auto-update → systemd restart
  Purpose: Pull new images, deploy updates
  Strategy: Full recreation (systemd stop → start cycle)
  Current: docker-compose up -d --wait --remove-orphans
  Protection: Built-in rollback (podman auto-update feature)
  Note: Already recreates fresh containers via systemd lifecycle
```

**Implementation Plan:**

Add pre-start stale health detection to system service (HIGH PRIORITY):
- Detect containers in "starting" or "unhealthy" state for >5 minutes before reuse
- Time-based validation prevents removing legitimately slow-starting containers
- Remove stuck containers to force fresh creation
- Preserves fast path for healthy containers
- Low overhead, automatic remediation
- Configurable threshold per-stack if needed
- See `docs/research/container-lifecycle-analysis.md` Recommendation 1 for full implementation
- See `docs/decisions/2026-02-12-container-lifecycle-strategy.md` for decision rationale

**Why NOT --force-recreate:**
- Defeats purpose of incremental config changes
- Unnecessarily restarts ALL containers on every rebuild
- Slower deployments (2-5s overhead per container × 19 stacks)
- Causes downtime when only secrets/firewall rules changed
- User services already recreate via systemd lifecycle (no need there either)

## Important Files

- `flake.nix`: Entry point, defines outputs and imports
- `hosts.nix`: Single source of truth for fleet identity
- `nix/lib.nix`: Configuration factory functions
- `modules/nixos/profiles/base.nix`: Base profile for all NixOS hosts
- `vms/definitions.nix`: VM specifications and inventory
- `vms/proxmox-ops.sh`: Safe Proxmox operations wrapper
- `secrets/.sops.yaml`: Age key configuration for secrets

## CI/CD

- **GitHub Actions**: Daily `flake.lock` updates with auto-merge
- **Quality Gate**: All changes must pass `nix flake check`
- **Auto-updates**: Enabled on doc1 and igpu (03:00 daily with GC at 03:30)
- **Rolling Updates**: doc1 has rolling flake updates enabled via `homelab.ci.rollingFlakeUpdate`

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
