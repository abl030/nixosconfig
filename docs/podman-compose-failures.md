# Podman Infrastructure: Full Audit & Rewrite Research

Date: 2026-02-12

---

## Planned Trial Direction (Next Iteration)

We are planning a reliability trial to reduce orchestration complexity and stop stack health from blocking host activation.

Trial goals:
- Keep container health checks enabled, but stop using compose health as a deploy gate.
- Move from `compose up --wait` to `compose up -d --remove-orphans` for stack start.
- Keep `PODMAN_SYSTEMD_UNIT` invariant enforcement as a hard preflight requirement.
- Keep failures explicit via systemd and monitoring alerts, but avoid blocking `nixos-rebuild switch` on slow or stuck health transitions.

Scope for this trial:
- Start with runtime/deploy behavior (`--wait` removal) while preserving monitoring and auto-update signals.
- Evaluate whether stale-health precheck logic remains necessary once deploy gating is removed.
- If validated, continue simplifying toward fewer services/scripts and clearer ownership boundaries.

Implementation note:
- Phase 1 is now applied: deploy path uses `compose up -d --remove-orphans` (no compose `--wait` gating).
- Invariant enforcement for `PODMAN_SYSTEMD_UNIT` remains hard-fail.
- Further simplification work is deferred to Phase 2.

---

## Implementation Update (2026-02-13)

The repository has now moved beyond the audit state described below. Current behavior in `stacks/lib/podman-compose.nix` is:

- `podman compose` is used everywhere (`${podmanBin} compose`) with `up -d --remove-orphans` (no deploy-time `--wait` gating).
- Compose lifecycle is owned by a user unit named `${stackName}.service` (not `podman-compose@...`).
- A paired system secrets unit `${stackName}-secrets.service` handles decryption and restarts the user unit.
- Both units have bounded startup (`TimeoutStartSec=${startupTimeoutSeconds}s`, currently default 300s / 5m).
- Stale-health detection checks both label schemes and deduplicates IDs:
  - `io.podman.compose.project`
  - `com.docker.compose.project`
- Stale-health parsing is hardened for Podman `StartedAt` formats with timezone names by normalizing to date/time/UTC-offset before `date -d`.
- Label mismatch precheck is hard-fail: containers with incorrect `PODMAN_SYSTEMD_UNIT` are removed before startup, preventing auto-update/restart drift.

### Observed Failure Mode (2026-02-13, AWST)

During the daily auto-update window, both container hosts reported the same error class:

- `doc1` (`proxmox-vm`) at ~`00:06`: `52` errors
- `igpu` at ~`00:14`: `13` errors
- Error text: `auto-updating container "<id>": no PODMAN_SYSTEMD_UNIT label found`

What this means:

- Containers had `io.containers.autoupdate=registry` but did not have `PODMAN_SYSTEMD_UNIT`.
- `podman auto-update` could detect update candidates, but had no restart unit to target.
- This is an auto-update metadata/invariant failure, not necessarily a runtime outage.

### Decision (Applied)

Enforce this invariant at stack preflight with hard-fail semantics:

- If `io.containers.autoupdate=registry` is set, `PODMAN_SYSTEMD_UNIT` must be present.
- Violation must fail startup immediately (preflight), not defer failure to timer-time auto-update.

The remainder of this document is preserved as historical audit context and migration rationale.

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

### Phase 1.5: Migrate Podman Socket to User Scope (Low Risk)

Move the podman API service from system scope to native user scope. This aligns with podman's official architecture and improves reliability.

**Why migrate:**
- Official podman documentation recommends user services for rootless sockets
- System services with `User=` have known issues: no session context, manual environment setup, sd_notify rejection
- Native user services get automatic environment, socket activation, proper logging
- Low risk: socket path doesn't change (`/run/user/1000/podman/podman.sock`)

**Implementation:**

1. Remove custom system service from `modules/nixos/homelab/containers/default.nix`:
   ```nix
   # DELETE systemd.services.podman-system-service = { ... };
   ```

2. Enable NixOS-provided user socket and service:
   ```nix
   systemd.user.sockets.podman = {
     wantedBy = ["sockets.target"];
   };

   systemd.user.services.podman = {
     # Socket activation will start this on-demand
   };
   ```

3. Linger already enabled (no change needed):
   ```nix
   users.users.${user}.linger = true;  # ✓ Already present
   ```

4. Test that:
   - Socket created at `/run/user/1000/podman/podman.sock` on boot
   - Existing stack services can still connect (they explicitly set `CONTAINER_HOST`)
   - `podman ps` works for the rootless user
   - Service starts on-demand when socket is accessed

**Rollback:** Re-enable the system service, disable user socket/service.

**Reference:** See Appendix D for detailed research on socket scope best practices.

**Status: ✅ COMPLETE (2026-02-12)**

Successfully deployed to both hosts:
- proxmox-vm (19 stacks)
- igpu (5 stacks)

**Implementation Learnings:**

1. **User session dependency required** - System stack services must depend on `user@.service`:
   ```nix
   requires = requires ++ ["user@${toString userUid}.service"];
   after = after ++ ["user@${toString userUid}.service"];
   ```
   Without this, services start before the user socket is available, causing `dial unix /run/user/1000/podman/podman.sock: connect: no such file or directory`.

2. **Stale health detection date parsing issues:**
   - **Problem 1:** Podman's `StartedAt` format includes timezone abbreviation (e.g., `2026-02-12 21:03:38 +0800 AWST`)
   - **Fix:** Strip timezone abbreviation using `awk "{print \$1, \$2, \$3}"` to get parseable format
   - **Problem 2:** Systemd interprets `%` as variable specifier, so `date +%s` became `date +/run/current-system/sw/bin/bash`
   - **Fix:** Escape `%` as `%%` in systemd unit files: `date +%%s`

3. **Socket stale state during rebuild:**
   - **Problem:** When transitioning from system service to user socket, the socket file could disappear even though systemd reported "active (listening)"
   - **Root cause:** Stopping old `podman-system-service` could interfere with user socket, leaving it in stale state
   - **Fix:** Add activation script to restart user socket during system activation:
   ```nix
   system.activationScripts.podmanUserSocket = lib.stringAfter ["users"] ''
     export XDG_RUNTIME_DIR=/run/user/${toString userUid}
     if /run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/systemctl --user is-enabled podman.socket 2>/dev/null; then
       /run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/systemctl --user restart podman.socket || true
     fi
   '';
   ```
   **Note:** This script only restarts the socket (API endpoint), not containers, so it has zero impact on container uptime.

4. **Commits:**
   - `3c4f953` - Initial socket migration
   - `faf71e6` - Add user session dependency
   - `26ea1ed` - Fix date parsing (timezone stripping)
   - `d4811e6` - Fix systemd % escaping
   - `a499788` - Add activation script (initial attempt)
   - `0e0d050` - Fix activation script to use runuser

### Phase 2: Split Services by Privilege (Medium Risk)

This is the core architectural change. Separate SOPS decryption from compose lifecycle.

**Architectural Decisions (2026-02-12):**

1. **Multi-file secrets:** Preserve separation - each stack's env files stay separate (no merging). System service decrypts all `envFiles` to their respective paths in `/run/user/<uid>/secrets/`. User service passes multiple `--env-file` args to compose.

2. **SOPS sharing:** Verified no stacks share SOPS files (24 stacks use unique `encEnv`, 1 uses `encAcmeEnv`). No thundering herd risk from shared secret changes.

3. **Cleanup script:** Simplify to only handle orphaned health check timers. Remove redundant container/pod pruning (global timer handles it). See Appendix F for detailed research.

4. **Restart triggers:** Keep simple - system service always reruns decrypt + bounce, even if only compose file changed.

**Implementation:**

1. Rewrite `mkService` in `stacks/lib/podman-compose.nix` to generate two services per stack:

   **System service** (`${stackName}-secrets.service`):
   ```nix
   systemd.services."${stackName}-secrets" = {
     description = "SOPS secrets for ${stackName}";

     # Wait for user session to exist
     after = ["user@${toString userUid}.service"];
     requires = ["user@${toString userUid}.service"];

     serviceConfig = {
       Type = "oneshot";
       RemainAfterExit = true;
       # Runs as root (default) for SOPS decryption using /var/lib/sops-nix/key.txt

       ExecStartPre = "/run/current-system/sw/bin/mkdir -p /run/user/${toString userUid}/secrets";

       # Decrypt ALL envFiles to their separate paths in /run/user/<uid>/secrets/
       # Preserve multi-file structure (no merging)
       ExecStart = [ (mkDecryptSteps envFiles) ];

       ExecStartPost = [
         # Fix permissions for all decrypted files
         (mkChmodSteps envFiles)
         (mkChownSteps envFiles)
         # Bounce user service using runuser + explicit XDG_RUNTIME_DIR
         # The + prefix grants root privileges for the runuser command
         "+/run/current-system/sw/bin/runuser -u ${user} -- sh -c 'export XDG_RUNTIME_DIR=/run/user/${toString userUid}; systemctl --user restart ${stackName}.service'"
       ];
     };

     # Restart when ANY SOPS file OR compose file changes (trigger proxy)
     # NixOS doesn't restart user services on rebuild, so system service acts as proxy
     # Even if only compose changes, rerun decrypt (simpler than conditional logic)
     restartTriggers = [composeFile] ++ (map (env: env.sopsFile) envFiles);
     wantedBy = ["multi-user.target"];
   };
   ```

   **User service** (`${stackName}.service`):
   ```nix
   systemd.user.services."${stackName}" = {
     description = "Podman compose for ${stackName}";

     # Wait for podman socket
     after = ["podman.socket"];
     wants = ["podman.socket"];

     serviceConfig = {
       Type = "oneshot";
       RemainAfterExit = true;

       Environment = [
         "PODMAN_SYSTEMD_UNIT=${stackName}.service"  # Points to self for auto-update
         "XDG_RUNTIME_DIR=/run/user/${toString userUid}"  # Explicit is safer than relying on auto-set
       ];

       # Verify ALL env files exist with retry (handles boot timing edge cases)
       ExecStartPre = (mkEnvFileChecks envFiles);

       # Pass all env files separately to compose (preserve multi-file structure)
       ExecStart = "${podmanCompose} -f ${composeFile} ${mkEnvArgs envFiles} up -d --wait --remove-orphans";
       ExecStop = "${podmanCompose} -f ${composeFile} stop";

       # Simplified cleanup: only orphaned health check timers
       # Removed: container prune (redundant), pod prune (obsolete)
       ExecStartPost = stackCleanupSimplified;
       ExecStopPost = stackCleanupSimplified;
     };

     wantedBy = ["default.target"];
     # Don't restart on nixos-rebuild - system service handles triggering via ExecStartPost bounce
     restartIfChanged = false;
   };
   ```

2. Simplify `stackCleanup` script (remove redundant operations):
   ```nix
   stackCleanupSimplified = pkgs.writeShellScript "podman-stack-cleanup" ''
     set -euo pipefail

     # Clean up orphaned health check timers (podman bug - timers not removed with containers)
     active_ids=$(${podmanBin} ps -q 2>/dev/null | tr '\n' '|')
     active_ids="''${active_ids%|}"
     if [ -z "$active_ids" ]; then
       active_ids="NONE"
     fi
     /run/current-system/sw/bin/systemctl --user list-units --plain --no-legend --type=timer \
       | /run/current-system/sw/bin/grep -E '^[0-9a-f]{64}-' \
       | /run/current-system/sw/bin/awk '{print $1}' \
       | while read -r timer; do
           cid="''${timer%%-*}"
           if ! echo "$cid" | /run/current-system/sw/bin/grep -qE "^($active_ids)"; then
             /run/current-system/sw/bin/systemctl --user stop "$timer" 2>/dev/null || true
           fi
         done
     /run/current-system/sw/bin/systemctl --user reset-failed 2>/dev/null || true
   '';
   ```
   **Removed:**
   - `sleep 2` - unnecessary delay
   - `podman container prune -f --filter "until=60s"` - redundant (global timer handles with 4h threshold)
   - `podman pod prune -f` - obsolete (docker-compose backend doesn't create pods)

   **Kept:**
   - Orphaned health check timer cleanup (addresses ongoing podman systemd integration bug)
   - `systemctl --user reset-failed` (defensive recovery)

3. Remove the old dual-service architecture (old system service + old user service with same names)

4. Test that:
   - Stacks come up on boot (linger → user session → user services start)
   - `podman auto-update` restarts the user service correctly
   - Changing one stack's compose file only restarts that stack (per-stack granularity)
   - nixos-rebuild with SOPS changes re-decrypts and bounces the user service
   - nixos-rebuild with compose changes triggers system service which bounces user service
   - System service depends on `user@.service` so it waits for user session
   - Multi-file env files all get decrypted and passed to compose
   - No journal spam from orphaned health check timers
   - Stack operations complete ~2-3s faster (removed redundant container/pod pruning)

5. Deploy to doc1

**Rollback:** Revert `podman-compose.nix` to generate the old service structure.

**Reference:**
- Appendix C: Cross-scope service management research
- Appendix D: Socket scope research
- Appendix F: Cleanup script necessity research

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

## Appendix C: Systemd Cross-Scope Service Management (Research: 2026-02-12)

### Problem: How to Restart User Services from System Service Context

System services (running as root) need to restart user services after completing privileged setup work (SOPS decryption). This crosses systemd's privilege boundary.

### Solution: `runuser` with Explicit Environment

**Correct pattern:**
```bash
+/run/current-system/sw/bin/runuser -u <username> -- sh -c 'export XDG_RUNTIME_DIR=/run/user/<uid>; systemctl --user restart <service>'
```

**Key components:**

1. **`+` prefix** - In systemd service definitions, grants root privileges to the command (replaces deprecated `PermissionsStartOnly=true`)

2. **`runuser`** - Root-only command that switches to user context without requiring password or sudo
   - Does NOT require setuid permissions
   - Uses separate PAM config from `su`
   - Properly initializes user environment

3. **`XDG_RUNTIME_DIR`** - MUST be explicitly set for `systemctl --user` to work
   - Points to `/run/user/<uid>` where user systemd manager socket lives
   - Without this, `systemctl --user` cannot connect to user session

4. **Dependencies** - System service MUST depend on user session:
   ```nix
   after = ["user@${toString userUid}.service"];
   requires = ["user@${toString userUid}.service"];
   ```

5. **Linger** - User session must persist across logout:
   ```nix
   users.users.<username>.linger = true;
   ```

### Why Not Other Approaches?

- **Direct `systemctl --user`** - Fails without XDG_RUNTIME_DIR set
- **`sudo systemctl --user`** - sudo blocks setting XDG_RUNTIME_DIR for security reasons
- **`systemd-run --user --machine`** - Requires interactive auth when not root, more complex
- **`machinectl shell`** - Interactive only, overhead of full shell initialization

### NixOS-Specific Notes

- `PermissionsStartOnly` is deprecated ([nixpkgs#53852](https://github.com/NixOS/nixpkgs/issues/53852)) - use `+` prefix instead
- NixOS does NOT restart user services on `nixos-rebuild` ([nixpkgs#246611](https://github.com/NixOS/nixpkgs/issues/246611)) - system service acts as "trigger proxy"
- User linger ensures user systemd instance starts at boot and persists

### References

- [systemd.service - Freedesktop](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
- [Systemd/User Services - NixOS Wiki](https://wiki.nixos.org/wiki/Systemd/User_Services)
- [systemd/User - ArchWiki](https://wiki.archlinux.org/title/Systemd/User)
- [Restarting Systemd Service With Specific User - Baeldung](https://www.baeldung.com/linux/systemd-service-restart-specific-user)

## Appendix D: Podman Rootless Socket Scope (Research: 2026-02-12)

### Problem: Should Podman API Service Be System or User Scope?

Current implementation uses a system service (`systemd.services.podman-system-service`) with `User=abl030` directive. Is this correct?

### Answer: User Service is Correct Architecture

**Recommendation:** Migrate to native user service with socket activation.

### Comparison

| Aspect | System Service + User= | Native User Service |
|--------|------------------------|---------------------|
| **Environment** | Manual (HOME, XDG_RUNTIME_DIR, PATH) | Automatic |
| **Socket Activation** | Manual `podman system service` | Native systemd .socket/.service |
| **Logging** | System journal (harder to isolate) | User journal (proper isolation) |
| **D-Bus Access** | No session bus | Full session bus |
| **Resource Efficiency** | Always running (Type=simple) | On-demand via socket |
| **Official Support** | Not documented | Official podman docs |
| **Known Issues** | sd_notify rejection, missing session | None |

### Why User Service?

**From official podman documentation** ([podman-system-service](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html)):
> The user service socket is configured as a Unix socket at `/usr/lib/systemd/user/podman.socket`, which listens on `$XDG_RUNTIME_DIR/podman/podman.sock` (e.g., `/run/user/1000/podman/podman.sock`).

**Known issues with system service + `User=`** ([podman#12778](https://github.com/containers/podman/issues/12778)):
> User= does not set the environment for rootless to work correctly: it does not set the user session so there are no tmp dirs, as well as no journal for logs.

**Systemd team recommendation** ([podman discussions](https://github.com/containers/podman/discussions/20573)):
> Use systemd --user instead of the main systemd instance + User=.

### Implementation: Enable Native User Service

NixOS already ships with podman user socket/service units. Just enable them:

```nix
systemd.user.sockets.podman = {
  wantedBy = ["sockets.target"];
};

systemd.user.services.podman = {
  # Socket activation starts this on-demand
};
```

### Migration Risk: LOW

**Socket path is identical:**
- Before: `/run/user/1000/podman/podman.sock` (created by system service)
- After: `/run/user/1000/podman/podman.sock` (created by user socket)

Existing system services with `CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock` continue working unchanged.

### User Service Dependencies

Stack user services should depend on socket:
```nix
after = ["podman.socket"];
wants = ["podman.socket"];
```

Boot flow with linger:
1. `user@1000.service` starts at boot (linger enabled)
2. User systemd activates `podman.socket` (WantedBy=sockets.target)
3. Stack services start (WantedBy=default.target, After=podman.socket)
4. First API call triggers `podman.service` via socket activation

### References

- [Podman System Service Documentation](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html)
- [Podman Socket Activation Tutorial](https://github.com/containers/podman/blob/main/docs/tutorials/socket_activation.md)
- [Red Hat: Rootless Podman with Systemd](https://www.redhat.com/en/blog/painless-services-implementing-serverless-rootless-podman-and-systemd)
- [NixOS Wiki: Systemd User Services](https://wiki.nixos.org/wiki/Systemd/User_Services)

## Appendix F: Cleanup Script Necessity Analysis (Research: 2026-02-12)

### Problem: Is stackCleanup Still Needed with Docker-Compose Backend?

The current `stackCleanup` script runs after every stack operation and performs three tasks:
1. Prune stopped containers (>60s old)
2. Prune dead pods
3. Clean up orphaned health check timers

This was implemented as a "kludge" during the podman-compose era. With the migration to docker-compose backend, do we still need it?

### Research Findings

#### Container Pruning: REDUNDANT ❌

**Current behavior:**
- Runs `podman container prune -f --filter "until=60s"` after every stack operation
- Executed ~38 times/day on doc1 (19 stacks × 2 operations)

**Why redundant:**
- Global `podman-rootless-prune` timer already runs daily with 4-hour threshold
- `docker-compose up --remove-orphans` handles orphaned containers during stack updates
- Stale health detection (commit e194187) removes problematic containers before reuse
- Containers stopped <60 seconds rarely cause issues

**Overhead:** ~2-3 seconds per stack operation, executed 38x/day unnecessarily

**Verdict:** Remove from stackCleanup, rely on global timer.

#### Pod Pruning: OBSOLETE ❌

**Current behavior:**
- Runs `podman pod prune -f` after every stack operation
- Also runs targeted `podman pod rm -f pod_${projectName}` in ExecStartPre

**Why obsolete:**
- Docker-compose backend uses bridge networking, NOT pods
- `podman-compose` created pods by default; `podman compose` does not
- Legacy pods from podman-compose era cleaned up during Phase 1 migration
- Verification on doc1/igpu shows zero compose-created pods

**Verdict:** Remove from stackCleanup entirely.

#### Health Check Timer Cleanup: STILL NECESSARY ✅

**Current behavior:**
- Identifies systemd timers for containers that no longer exist
- Stops orphaned timers to prevent journal spam

**Why still necessary:**
- **Podman bug:** Containers removed with `podman rm -f` don't always clean up health check timers
- **User impact:** Orphaned timers spam journal with "container not found" every 30 seconds
- **Docker-compose doesn't help:** Timers managed by podman, not compose tool
- **Immediate remediation:** Per-stack cleanup catches orphans right after container removal (vs 24-hour wait for global timer)

**Evidence:**
- Podman issues [#7484](https://github.com/containers/podman/issues/7484), [discussions #19485](https://github.com/containers/podman/discussions/19485)
- Bug persists across podman versions and compose tool choices
- Stale health detection (commit e194187) can orphan timers when removing stuck containers

**Verdict:** Keep in both per-stack cleanup (immediate) and global timer (catch-all).

### Recommendation: Simplify stackCleanup

**Remove:**
- Container pruning (60s threshold) - redundant with global timer
- Pod pruning - obsolete with docker-compose backend
- `sleep 2` delay - unnecessary without prune operations

**Keep:**
- Orphaned health check timer cleanup
- `systemctl --user reset-failed`

**Benefits:**
- Eliminates ~2-3 seconds overhead per stack operation
- Reduces duplicate work (38 container scans/day → 1/day)
- Maintains critical timer cleanup for immediate bug remediation
- Simpler, more focused script

### Simplified Implementation

```bash
stackCleanupSimplified = pkgs.writeShellScript "podman-stack-cleanup" ''
  set -euo pipefail

  # Clean up orphaned health check timers
  active_ids=$(podman ps -q 2>/dev/null | tr '\n' '|')
  active_ids="''${active_ids%|}"
  if [ -z "$active_ids" ]; then
    active_ids="NONE"
  fi
  systemctl --user list-units --plain --no-legend --type=timer \
    | grep -E '^[0-9a-f]{64}-' \
    | awk '{print $1}' \
    | while read -r timer; do
        cid="''${timer%%-*}"
        if ! echo "$cid" | grep -qE "^($active_ids)"; then
          systemctl --user stop "$timer" 2>/dev/null || true
        fi
      done
  systemctl --user reset-failed 2>/dev/null || true
'';
```

### References

- [Docker Compose --remove-orphans behavior](https://github.com/docker/compose/issues/6637)
- [Podman system prune documentation](https://docs.podman.io/en/latest/markdown/podman-system-prune.1.html)
- [Podman health check timer issues](https://github.com/containers/podman/discussions/19381)
- [Container lifecycle analysis](/home/abl030/nixosconfig/docs/research/container-lifecycle-analysis.md)

## Appendix G: Previous Session Findings

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
