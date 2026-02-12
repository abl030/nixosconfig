# Podman Infrastructure: Full Audit & Rewrite Research

Date: 2026-02-12

---

## Part 1: How Everything Currently Works

### Architecture Overview

The container infrastructure runs **rootless podman** on `proxmox-vm` (doc1) with 19 compose stacks and on `igpu` with 5 stacks. Everything is orchestrated through a custom Nix abstraction layer that generates systemd services from docker-compose.yml files.

**Key files:**
- `stacks/lib/podman-compose.nix` — the single abstraction layer; every stack calls `podman.mkService`
- `modules/nixos/homelab/containers/default.nix` — NixOS module for podman, auto-update, cleanup
- `modules/nixos/homelab/containers/stacks.nix` — registry mapping stack names to Nix modules
- `hosts.nix` — `containerStacks` list per host selects which stacks to enable

### The `mkService` Abstraction

Each stack (e.g. `stacks/immich/docker-compose.nix`) imports `stacks/lib/podman-compose.nix` and calls `podman.mkService { ... }`. This generates:

1. **A system-level oneshot service** (`systemd.services.${stackName}`):
   - `Type = oneshot; RemainAfterExit = true`
   - `ExecStartPre`: waits for podman socket, decrypts SOPS env files, prunes legacy pods, detects label mismatches
   - `ExecStart`: `podman-compose --in-pod false -f <compose.yml> --env-file <decrypted.env> up -d --remove-orphans`
   - `ExecStop`: `podman-compose ... stop`
   - `ExecStartPost` / `ExecStopPost`: cleanup script to prune dead containers, pods, and orphan health check timers
   - Runs as the rootless user (`User = abl030`), connects to rootless socket via `CONTAINER_HOST`
   - `Restart = on-failure`, `RestartSec = 30s`, 5 retries in 5 minutes
   - `restartTriggers` tied to compose file and SOPS env files (nixos-rebuild restarts on config change)
   - All stacks `wants`/`after` `podman-system-service.service`
   - Injects `PODMAN_SYSTEMD_UNIT=podman-compose@${projectName}.service` as environment variable

2. **A user-level oneshot service** (`systemd.user.services.podman-compose@${projectName}`):
   - Same compose commands as the system service
   - Exists as the target for `podman auto-update`'s PODMAN_SYSTEMD_UNIT label
   - Wanted by `default.target` (starts on user session init via linger)

3. **Firewall rules, proxy hosts, monitoring, and Loki scrape targets** — all wired through the same `mkService` call.

### The Container Module (`default.nix`)

Provides:
- `homelab.containers.enable` — master switch
- `homelab.containers.dataRoot` — defaults to `/mnt/docker`
- `homelab.containers.autoUpdate.{enable, schedule}` — auto-update timer (default: daily)
- `homelab.containers.cleanup.{enable, schedule, maxAge}` — prune timer

Creates:
- `podman-system-service` — long-running service that runs `podman system service --time=0` to expose the rootless podman API socket
- `podman-auto-update` — oneshot service with custom script that: runs `podman auto-update`, captures output, detects updated containers, waits 30s, checks container status, runs `--dry-run` to detect rollbacks, sends Gotify notification on failure
- `podman-rootless-prune` — oneshot service that prunes old containers/pods and cleans orphaned health check timers
- Timers for both auto-update and prune

Also configures: `virtualisation.podman`, `security.unprivilegedUsernsClone`, `newuidmap`/`newgidmap` setuid wrappers, user linger, subuid/subgid ranges (100000+65536), custom `storage.conf` with fuse-overlayfs, installs `podman-compose`, `buildah`, `skopeo`, `netavark`, `aardvark-dns`.

### The Stack Registry (`stacks.nix`)

Maps 26 stack names to their Nix module paths. `hosts.nix` lists `containerStacks` per host. `stacks.nix` imports only the modules for enabled stacks, with assertions for unknown stack names.

**proxmox-vm runs 19 stacks:** management, tailscale-caddy, immich, paperless, mealie, kopia, atuin, audiobookshelf, domain-monitor, invoices, jdownloader2, music, netboot, smokeping, stirlingpdf, tautulli, uptime-kuma, webdav, youtarr.

**igpu runs 5 stacks:** igpu-management, tdarr-igp, jellyfin, plex, loki.

### Compose Files

Standard docker-compose.yml files. All containers have `io.containers.autoupdate=registry` labels. Several stacks use the "network holder" pattern (a `pause:3.9` container that owns the port mappings, other containers attach via `network_mode: "service:network-holder"`). Some stacks include Tailscale sidecar containers and Caddy reverse proxies within the compose stack. Many compose files still have `version: "3.8"` (harmless but deprecated).

### Auto-Update Workflow

1. Timer fires daily (default midnight)
2. Custom script runs `podman auto-update` as rootless user
3. Podman checks each container with `io.containers.autoupdate=registry` label for image digest changes
4. For changed images: pulls new image, restarts the systemd unit named in `PODMAN_SYSTEMD_UNIT` label
5. If restart fails (unhealthy), podman rolls back to previous image
6. Our script waits 30s, then checks container states and runs `--dry-run` to detect rollbacks
7. On any failure or rollback, sends Gotify notification

---

## Part 2: What's Wrong (Root Cause Analysis)

### Problem 1: Thundering Herd on nixos-rebuild

When `nixos-rebuild switch` runs, systemd restarts **all ~19 stack services simultaneously**. Each runs `podman-compose up -d`, which shells out to `podman` CLI commands sequentially. 19 concurrent processes all hitting podman's SQLite database at once causes lock contention.

**Impact:** Containers silently fail to create. Dependency chains break. Stacks come up partially or not at all. The systemd service reports success (ExecStart exited 0 even though containers are broken) because `podman-compose` doesn't propagate container creation failures properly.

**Root cause:** `podman-compose` is a thin Python wrapper that runs `podman create`, `podman start` etc. sequentially via subprocess calls. It does not use the podman API, does not properly handle errors, and does not report failures as nonzero exit codes in all cases.

**SQLite detail:** The podman team actually *disabled* WAL (Write-Ahead Logging) mode in their SQLite backend ([PR #18519](https://github.com/containers/podman/pull/18519)) because it made concurrent CLI access *worse*, not better. This is counter-intuitive — WAL normally improves concurrency — but podman's access pattern (many separate processes each opening their own connection) conflicted with WAL's assumptions. Additional retry mechanisms were added in [PR #20838](https://github.com/containers/podman/pull/20838) for concurrent `podman exec` / `podman rm` scenarios, but the fundamental problem remains: many concurrent CLI invocations fight over exclusive SQLite locks.

### Problem 2: podman-compose Error Handling

`podman-compose` has known, unfixed issues:
- Hangs in `epoll_wait` when container creation fails instead of exiting
- Does not support `--wait` flag (waits until containers are healthy)
- Prevents updating a single service without affecting dependents
- Version 1.1.0+ broke Containerfile support
- Mounting issues with Python dotenv
- The project is functionally abandoned by core podman maintainers in favour of Quadlet

### Problem 3: PODMAN_SYSTEMD_UNIT Label Mismatch

`podman auto-update` requires the `PODMAN_SYSTEMD_UNIT` label to know which systemd unit to restart. Our setup injects it as an **environment variable** (`PODMAN_SYSTEMD_UNIT=podman-compose@${projectName}.service`), which podman picks up at container-creation time and stores as a container label.

But there are **two services** per stack: the system service (`${stackName}`, e.g. `immich-stack`) and the user service (`podman-compose@immich`). The label points to the user service. When auto-update restarts the user service, it runs `podman-compose up -d` again — but this is the user service, which doesn't run the ExecStartPre steps (SOPS decryption, socket wait, pod cleanup). If the env file has expired or the socket isn't ready, it fails.

### Problem 4: Dual Service Architecture Mixes Concerns

Each stack has a system service AND a user service doing the same compose work. The system service exists because it needs `PermissionsStartOnly = true` to run SOPS decryption as root in ExecStartPre, then ExecStart runs as the rootless user. The user service exists as the auto-update restart target.

The real issue is that **two concerns are mixed into one service**: privileged work (SOPS decryption, directory creation) and unprivileged work (running `podman compose up`). This mixing forces the compose lifecycle into a system service, which `podman auto-update` (running rootless) **cannot restart** — it calls `systemctl --user restart`, not `systemctl restart`.

The result:
- Confusion about which service "owns" the containers
- Race conditions if both try to operate simultaneously
- The system service restarts on nixos-rebuild; the user service is what auto-update targets
- Container label points to user service, but the system service is what nixos-rebuild manages
- Auto-update restarts the user service which lacks the SOPS pre-start steps

**The fix:** Split the services by privilege boundary. A system service does the privileged prep work (SOPS decrypt to `/run/user/<uid>/secrets/`, directory creation, ownership). A user service owns the compose lifecycle exclusively. `podman auto-update` restarts the user service natively — no sudo, no hacks. The decrypted env files persist in `/run/user/<uid>/secrets/` (tmpfs backed by linger) across user service restarts.

### Problem 5: Simultaneous Startup (Solved by API Socket)

All 19 stacks start simultaneously on boot/rebuild. With `podman-compose` (CLI forks), this caused SQLite lock contention — the thundering herd.

With `podman compose` (docker-compose backend), this is no longer a correctness problem. docker-compose talks to the podman API socket, and the daemon serializes all database access internally. 19 stacks starting simultaneously just means 19 queued API requests handled sequentially — no lock contention, no silent failures. This is exactly how Docker has always worked.

**No explicit staggering needed.** The API socket is the natural throttle. Resource pressure (CPU, memory, network during image pulls) is manageable on an 8-core 32GB VM and doesn't warrant complex tier-based ordering. Staggering would add complexity for a problem that the compose tool swap already solves.

### Problem 6: Auto-Update Rollback Detection Is Fragile

The auto-update script:
1. Runs `podman auto-update` — podman updates and potentially rolls back
2. Waits 30 seconds (hardcoded)
3. Checks if containers are running
4. Runs `--dry-run` to see if containers still show as needing update (indicating rollback)

This is fragile because:
- 30s may not be enough for slow-starting containers
- No SDNOTIFY integration — podman can't reliably detect if the updated container is actually healthy
- Without `--sdnotify=container`, podman considers the restart successful if the unit starts, even if the container crashes 5 seconds later. The default `--sdnotify=conmon` mode reports success immediately.
- A proposed `--sdnotify=healthy` mode (wait for N passing healthchecks) has been discussed upstream but is not yet implemented
- The script correctly identifies the problem but can't fix it

### Problem 7: `--in-pod false` Workaround

`podman-compose` by default creates a pod for each compose project. Pods have their own issues — critically, restarting one container in a pod restarts **all containers in the pod** ([podman #15177](https://github.com/containers/podman/issues/15177)). This is by design (shared network namespace) but causes cascading restarts. The `--in-pod false` flag works around this but is a podman-compose-specific flag that wouldn't exist in `podman compose` or Quadlet.

This also affects networking: pod-mode forces all containers onto `localhost` (shared network namespace), breaking Docker Compose's service-name DNS resolution (e.g. `db:5432` becomes `localhost:5432`). Our stacks already use `--in-pod false` to avoid this, but it's another reason to move away from `podman-compose` entirely — `podman compose` (with docker-compose backend) uses proper bridge networking with `aardvark-dns` by default, no flag needed.

---

## Part 3: Available Options

### Option A: Replace `podman-compose` with `podman compose` (Minimal Change)

`podman compose` is a built-in podman subcommand (since podman 4) that wraps an external compose provider. By default it delegates to `docker-compose` (the Go-based Docker Compose v2) or falls back to `podman-compose`.

**What changes:**
- Replace `podman-compose --in-pod false` with `podman compose` in `podman-compose.nix`
- Remove `podman-compose` from `systemPackages`
- Install `docker-compose` (Go binary) — the actual engine `podman compose` will use
- Compose YAML files stay identical

**What it fixes:**
- Proper error handling (docker-compose exits nonzero on failure)
- Supports `--wait` flag (blocks until containers are healthy)
- Proper dependency ordering within a stack
- No pod creation by default
- Better DNS resolution (uses compose networking, not pod networking)

**What it doesn't fix:**
- Dual service architecture
- PODMAN_SYSTEMD_UNIT complexity
- Auto-update can't restart system services (privilege mismatch)

**Effort:** Small. ~20 lines changed in `podman-compose.nix` and `default.nix`.

### Option B: `podman compose` + Split Services by Privilege (Recommended)

Everything from Option A, plus a clean separation of concerns:

1. **Split each stack into two services by privilege boundary:**
   - **System service** (`${stackName}-secrets.service`): runs as root, does SOPS decryption to `/run/user/<uid>/secrets/`, creates data directories, fixes ownership. `Type=oneshot`, `RemainAfterExit=true`. This runs at boot and on nixos-rebuild when secrets or compose files change.
   - **User service** (`${stackName}.service` in user scope): runs `podman compose up --wait`, owns the full compose lifecycle. `PODMAN_SYSTEMD_UNIT` points here. This is what `podman auto-update` restarts natively via `systemctl --user restart`.
   - The user service has an `ExecStartPre` that verifies the decrypted env file exists (short retry loop). Since linger ensures the user session exists at boot and the secrets service runs early, the env files will be present by the time user services start.
   - **Important NixOS limitation:** `nixos-rebuild switch` does NOT restart user services ([nixpkgs #246611](https://github.com/NixOS/nixpkgs/issues/246611)). The system secrets service acts as the "trigger proxy" — its `restartTriggers` include BOTH SOPS files AND the compose file. When either changes, the system service reruns and its `ExecStartPost` bounces the user service via `systemctl --user restart`. This gives us per-stack granularity: changing one stack's compose file only restarts that stack.

2. **`podman auto-update` works natively.** Running as the rootless user, it calls `systemctl --user restart <unit>` — which is exactly the user service. The decrypted env files already exist in `/run/user/<uid>/secrets/` (persisted by linger). No sudo, no PODMAN_SYSTEMD_UNIT hacks, no custom restart logic.

3. **No explicit staggering.** The switch from `podman-compose` (CLI forks → SQLite contention) to `podman compose` (docker-compose → API socket → serialized access) eliminates the thundering herd. All stacks start in parallel; the podman daemon serializes database access internally. This is how Docker has always worked. Resource pressure on an 8-core 32GB VM is manageable without tier ordering.

4. **Use `podman compose up --wait`** instead of bare `up -d`. This blocks until all containers pass health checks (or fail), giving us a real exit code for the systemd service.

5. **Simplify auto-update script:**
   - Let podman handle the full update + restart + rollback cycle natively
   - Our script just runs `podman auto-update --format "{{.Unit}} {{.Image}} {{.Updated}}"`
   - Parse output for `failed` or `rolled_back` entries
   - Send Gotify with specifics on failure
   - Drop the 30s sleep + dry-run approach entirely
   - Auto-update timer: use `RandomizedDelaySec=900` (15 min jitter) + `AccuracySec=1us` to prevent systemd grouping timers into the default 1-minute accuracy window

**What it fixes (on top of Option A):**
- Clean privilege separation — each service does exactly one job
- Auto-update works natively, no hacks
- Reliable health checking via `--wait`
- Cleaner auto-update with proper exit codes
- Per-stack restart granularity (only changed stacks restart on nixos-rebuild)

**Effort:** Medium. Rewrite of `podman-compose.nix` and `default.nix`. The key insight is that this is *simpler* than the current dual-service architecture, not more complex.

### Option C: Quadlet (Full Rewrite)

Quadlet is podman's native systemd integration (merged in podman 4.4). Instead of compose files, you write `.container`, `.network`, `.volume` files in `/etc/containers/systemd/` (rootful) or `~/.config/containers/systemd/` (rootless). Systemd's generator turns these into proper systemd units.

There's a NixOS module for this: [quadlet-nix](https://github.com/SEIAROTg/quadlet-nix). It maps Quadlet options directly into Nix, with Home Manager support for rootless containers.

**Advantages:**
- Native systemd integration — proper dependencies, ordering, journald, restart policies
- `AutoUpdate=registry` built into the `.container` file — no label hacks
- Each container is its own systemd unit — granular restart, status, logging
- No compose tool in the middle — direct podman ↔ systemd
- Declarative network/volume management
- `podlet` tool can auto-convert compose files to Quadlet files

**Disadvantages:**
- **Abandons compose files** — the biggest trade-off. You'd need to maintain `.container` files instead (or Nix expressions via quadlet-nix). When upstream projects provide docker-compose.yml, you'd need to translate.
- **Significant rewrite** — every stack needs to be converted
- **Less portable** — compose files are industry-standard; Quadlet files are podman-only
- **Nix-specific tooling** — quadlet-nix is a third-party flake, not upstream NixOS

**Effort:** Large. Every stack needs conversion. All the compose YAML files are abandoned. New abstraction layer needed.

### Option D: Hybrid — `podman compose` for Stacks + Quadlet Principles

Keep compose files (industry standard, readable, portable). Use `podman compose` (with docker-compose backend) to run them. But adopt Quadlet-inspired patterns at the systemd level:

1. **Split services by privilege** — system service for secrets, user service for compose lifecycle
2. **Health checking via `--wait`** and proper exit codes
3. **Native `podman auto-update`** — works because compose lifecycle is in user services
4. **Gotify notifications** on failure

This is Option B — listed separately to contrast with Quadlet but it's the same architecture.

---

## Part 4: Recommendation

**Go with Option B** — `podman compose` + split services by privilege.

### Rationale

1. **Compose files stay.** You read them well, the industry has standardised on them, upstream projects ship them. Abandoning them for Quadlet means perpetual translation work.

2. **The root cause is `podman-compose`, not the architecture.** Replacing it with `docker-compose` (via `podman compose`) fixes error handling, `--wait` support, and API-based communication. These are the actual reliability wins. The API socket also eliminates the SQLite thundering herd — docker-compose serializes all access through the podman daemon, just like Docker always has.

3. **Splitting by privilege makes auto-update work natively.** The current dual-service mess exists because SOPS decryption (root) and compose lifecycle (rootless) are mixed in one service. Splitting them means the user service is the single owner of the compose lifecycle, and `podman auto-update` can restart it directly via `systemctl --user restart`. No sudo hacks, no PODMAN_SYSTEMD_UNIT workarounds. This is how rootless podman is designed to work.

4. **No staggering needed.** The API socket serializes concurrent access, eliminating the SQLite contention that caused the thundering herd. Docker never needed startup staggering and neither does podman once you use the API socket instead of CLI forks.

5. **Quadlet is overkill for this setup.** Quadlet shines when you need per-container systemd units and granular management. But our stacks are self-contained — immich has 7 containers that make sense as a unit. Managing 50+ individual `.container` files is worse than 19 compose files.

### Concrete Changes

#### `stacks/lib/podman-compose.nix` — Rewrite

```
Key changes:
- Replace podmanCompose binary with `podman compose` (podmanBin + " compose")
- Drop --in-pod false (not needed with docker-compose backend)
- Add --wait to `up -d` commands
- Split mkService output into two services:
  - System service (${stackName}-secrets): SOPS decrypt + directory creation only
  - User service (${stackName}): compose lifecycle (up/stop/reload)
- PODMAN_SYSTEMD_UNIT points to the user service name
- restartTriggers on system service: SOPS files + compose file (acts as trigger proxy)
- System service ExecStartPost: bounces user service via systemctl --user restart
- No startup ordering between stacks (API socket serializes access naturally)
```

#### `modules/nixos/homelab/containers/default.nix` — Simplify

```
Key changes:
- Remove podman-compose from systemPackages
- Add docker-compose (or ensure it's available as podman compose provider)
- Simplify auto-update script:
  - podman auto-update does the full cycle natively (pull, restart user unit, rollback)
  - Our script just parses the output and sends Gotify on failure
  - Drop the 30s sleep + dry-run approach
- Keep cleanup and prune services
- Auto-update timer: add RandomizedDelaySec=900, AccuracySec=1us
```

#### Per-Stack Restart Granularity

Each stack's system secrets service has its own `restartTriggers` scoped to that stack's files:

```nix
restartTriggers = [composeFile] ++ (map (env: env.sopsFile) envFiles);
```

When you change `stacks/immich/docker-compose.yml`:
1. `nixos-rebuild switch` diffs old vs new unit files
2. Only `immich-secrets.service` has a changed `X-Restart-Triggers` hash
3. NixOS restarts only that system service
4. Its `ExecStartPost` runs `systemctl --user restart immich.service`
5. Only immich's user service re-runs `podman compose up --wait`
6. All 18 other stacks: untouched

This works because NixOS **does** restart system services on config changes (via `switch-to-configuration`). It does NOT restart user services ([nixpkgs #246611](https://github.com/NixOS/nixpkgs/issues/246611)), which is why the system service acts as the trigger proxy.

#### User Service Dependency on System Service

The user service for each stack needs its secrets to exist before starting. The approach:

1. System secrets service is `WantedBy=multi-user.target` and runs early at boot
2. User service has an `ExecStartPre` that verifies the decrypted env file exists (short retry loop, max 30s)
3. Linger ensures the user session exists before system services run
4. On nixos-rebuild: the system service reruns and bounces the user service via `ExecStartPost`
5. On auto-update: podman restarts the user service directly — secrets already exist in `/run/user/<uid>/secrets/`

#### Auto-Update Flow (New)

```
Timer fires (user timer, daily + 15min jitter)
  → podman auto-update runs as rootless user
    → For each container with io.containers.autoupdate=registry:
      → Check registry for new digest
      → If new: pull image, restart PODMAN_SYSTEMD_UNIT (user service)
      → User service runs: podman compose up --wait (recreates with new image)
      → If health check fails: podman rolls back to previous image
  → Our wrapper script parses output
    → On any failure/rollback: send Gotify notification with details
    → On success: silent (or optional summary notification)
```

No custom rollback detection. No 30s sleep. No dry-run second pass. Podman handles the full lifecycle.

---

## Part 5: Migration Plan

### Phase 1: Replace podman-compose with podman compose (Low Risk)

Swap the compose tool without changing the service architecture. This is a safe, reversible change.

1. Update `stacks/lib/podman-compose.nix`:
   - Change ExecStart/ExecStop/ExecReload to use `podman compose` instead of `podman-compose`
   - Drop `--in-pod false` from default `composeArgs`
   - Add `--wait` to `up -d` commands
2. Update `modules/nixos/homelab/containers/default.nix`:
   - Remove `podman-compose` from systemPackages
   - Ensure `docker-compose` is available (check if nixpkgs has it, or use podman's built-in provider selection)
3. Test on sandbox or a single stack first
4. Deploy to doc1

**Rollback:** Revert the two files. `podman-compose` is still installed until Phase 1 is confirmed working.

### Phase 2: Split Services by Privilege (Medium Risk)

This is the core architectural change. Separate SOPS decryption from compose lifecycle.

1. Rewrite `mkService` to generate two services per stack:
   - **System service** (`${stackName}-secrets.service`):
     - `Type=oneshot; RemainAfterExit=true`
     - `ExecStartPre`: mkdir for secrets dir
     - `ExecStart`: SOPS decrypt env files to `/run/user/<uid>/secrets/${stackName}.env`
     - `ExecStartPost`: chmod 600, chown to rootless user, then `systemctl --user restart ${stackName}.service` (bounces user service)
     - `WantedBy=multi-user.target`
     - `restartTriggers` tied to BOTH SOPS source files AND compose file (acts as trigger proxy since NixOS doesn't restart user services — [nixpkgs #246611](https://github.com/NixOS/nixpkgs/issues/246611))
   - **User service** (`${stackName}.service` in `systemd.user.services`):
     - `Type=oneshot; RemainAfterExit=true`
     - `ExecStartPre`: verify env file exists (retry loop, max 30s)
     - `ExecStart`: `podman compose -f <compose.yml> --env-file <env> up -d --wait --remove-orphans`
     - `ExecStop`: `podman compose ... stop`
     - `ExecStartPost`: cleanup script
     - `Environment`: `PODMAN_SYSTEMD_UNIT=${stackName}.service` (points to itself)
     - `WantedBy=default.target`
     - `restartIfChanged=false` (system service handles restart triggering)
2. Remove the old dual-service architecture (old system service + old user service)
3. Move `podman-system-service` to a user service too (the podman socket belongs in user scope)
4. Test that:
   - Stacks come up on boot (linger → user session → user services start)
   - `podman auto-update` restarts the user service correctly
   - Changing one stack's compose file only restarts that stack (per-stack granularity)
   - nixos-rebuild with SOPS changes re-decrypts and bounces the user service
   - nixos-rebuild with compose changes triggers system service which bounces user service
5. Deploy to doc1

**Rollback:** Revert `podman-compose.nix` to generate the old service structure.

### Phase 3: Simplify Auto-Update (Low Risk)

Now that auto-update works natively, simplify the wrapper.

1. Rewrite auto-update script:
   - Run `podman auto-update --format "{{.Unit}} {{.Image}} {{.Updated}}"`
   - Parse for `failed` or `rolled_back` entries
   - Send Gotify on any failure with specifics
   - Exit 0 on full success, 1 on any failure
2. Remove the 30s sleep, dry-run detection, and double-execution workarounds
3. Add `RandomizedDelaySec=900` and `AccuracySec=1us` to the auto-update timer
4. Deploy

### Phase 4: Clean Up (Low Risk)

1. Remove `version: "3.8"` from compose files (deprecated key)
2. Add health checks to containers that don't have them (improves `--wait` reliability)
3. Ensure all images are fully-qualified (required for auto-update registry policy)
4. Remove orphaned compose files for disabled stacks
5. Verify BoltDB vs SQLite backend on doc1/igpu and migrate if needed (ahead of Podman 6.0)

---

## Appendix A: Podman Database Backend Timeline

Podman is migrating from BoltDB to SQLite. With `podman compose` (API socket), SQLite contention is no longer a practical concern — the daemon serializes access. However, we still need to be on the right backend before Podman 6.0.

| Version | Default Backend | Notes |
|---------|----------------|-------|
| Podman < 4.8 | BoltDB | Single-writer, simple but limited |
| Podman 4.8+ | SQLite | New installs use SQLite; existing BoltDB preserved |
| Podman 5.0 | SQLite | Officially default for all new installs |
| Podman 5.7 | SQLite | BoltDB deprecation warning displayed |
| Podman 5.8 | SQLite | BoltDB-to-SQLite migration tool added |
| **Podman 6.0 (mid-2026)** | **SQLite only** | **BoltDB codepaths entirely removed** |

**Migration path:** Users upgrading to 6.0 must stop at 5.8 first to use the migration tool. Prior to 5.8, the only migration path was `podman system reset` (destroys all data). We should verify which backend doc1/igpu are currently on and plan accordingly.

## Appendix B: Other NixOS Options Considered

Several NixOS-native approaches exist for container management. None are better than Option B for our use case, but they're documented here for completeness:

- **`virtualisation.oci-containers`** (built-in): Declares individual containers as systemd services. Has a [known bug](https://github.com/NixOS/nixpkgs/issues/425167) where custom `serviceName` breaks `PODMAN_SYSTEMD_UNIT` for auto-update. Too low-level for multi-container stacks.
- **[compose2nix](https://github.com/aksiksi/compose2nix)**: Converts docker-compose.yml into NixOS `oci-containers` declarations. One-time generation — doesn't stay in sync with upstream compose changes. Would lose the "read the compose file" benefit.
- **[quadlet-nix](https://github.com/SEIAROTg/quadlet-nix)**: Declarative Nix interface to Podman Quadlet (see Option C above). Full featured but abandons compose files.
- **[Arion](https://docs.hercules-ci.com/arion/)**: Nix-native composition tool built on Docker Compose. Replaces YAML with Nix expressions — opposite direction from "keep compose files readable".

## Appendix C: Previous Session Findings

### Why is podman-compose so bad?

The actual problem is **podman-compose**, not podman itself. It's a Python community project that shells out to `podman` CLI commands sequentially. When a container fails to create, it doesn't exit -- it just sits in `epoll_wait` forever. Docker Compose talks to the daemon API and handles errors properly. podman-compose is a much thinner, buggier wrapper.

### Why did invoices-stack fail?

The nixos-rebuild restarts **all ~20 stacks simultaneously**. Rootless podman uses a **SQLite database** for container state (`~/.local/share/containers/`). When 20 concurrent podman-compose processes all try to create containers at once, SQLite locking causes silent failures -- `ff-db` and `ff-redis` (which have zero dependencies and should be created first) simply never got created. The dependency errors for `ff-app`/`ff-importer`/`caddy` cascade from there.

**The proof:** the auto-restart (when most other stacks had already finished) succeeded immediately with zero errors. Same compose file, same images, same config -- just less contention.

### Why is podman-auto-update failing?

Two stacked problems:

**a) Double execution** — The base podman package provides its own `podman-auto-update.service`. Our NixOS module appended a second ExecStart. For oneshot services, systemd runs both sequentially. **Fix applied:** Clear the base ExecStart with `ExecStart = ["" autoUpdateScript];`.

**b) Rollback detection** — Our custom script detects rollbacks and exits 1, but it can't prevent them. Containers that fail health checks after update get rolled back every time. Without SDNOTIFY integration, the detection is based on a 30s wait + dry-run check, which is fragile.

### Changes made in previous session

- Commented out `slskd` and `soularr` in `stacks/music/docker-compose.yml` (not in use)
- Removed ports 5030/5031 from music network holder and firewall
- Fixed stray duplicate `labels:` key on `ff-importer` in `stacks/invoices/docker-compose.yml`
- Fixed double ExecStart in `modules/nixos/homelab/containers/default.nix`

## Appendix D: Research Sources

- [Podman Compose vs Docker Compose (Red Hat)](https://www.redhat.com/en/blog/podman-compose-docker-compose)
- [podman compose docs](https://docs.podman.io/en/latest/markdown/podman-compose.1.html)
- [podman auto-update docs](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html)
- [quadlet-nix (NixOS Quadlet module)](https://github.com/SEIAROTg/quadlet-nix)
- [Replace Docker Compose with Quadlet (Duggan)](https://matduggan.com/replace-compose-with-quadlet/)
- [podman-compose auto-update issue #534](https://github.com/containers/podman-compose/issues/534)
- [podman SQLite database locked #18356](https://github.com/containers/podman/issues/18356)
- [podman SQLite concurrent lock #20809](https://github.com/containers/podman/issues/20809)
- [Podman BoltDB to SQLite migration (Fedora)](https://discussion.fedoraproject.org/t/podman-5-7-boltdb-to-sqlite-migration/171172)
- [NixOS rootless podman with systemd](https://discourse.nixos.org/t/podman-rootless-with-systemd/23536)
- [NixOS oci-containers rootless issue #259770](https://github.com/NixOS/nixpkgs/issues/259770)
- [systemd RandomizedDelaySec (ArchWiki)](https://wiki.archlinux.org/title/Systemd/Timers)
- [Podman Quadlet (Red Hat)](https://www.redhat.com/en/blog/quadlet-podman)
- [podlet: compose to quadlet converter](https://github.com/containers/podlet)
