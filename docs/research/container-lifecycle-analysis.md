# Container Lifecycle Analysis: Rebuild vs Auto-Update

**Research Date:** 2026-02-12
**Related Beads:** nixosconfig-cm5 (research task), nixosconfig-hbz (stale container bug)
**Status:** Complete (implemented and hardened through 2026-02-13)
**Related empirical test:** [restart-probe-compose-change-test-2026-02-13.md](./restart-probe-compose-change-test-2026-02-13.md)

## Planned Trial Direction (2026-02)

The next iteration will trial a simpler deployment model while preserving health visibility:
- Keep container health checks active in compose definitions.
- Remove `--wait` from stack deploy path so host activation is not blocked by runtime health convergence.
- Retain strict auto-update ownership invariant (`PODMAN_SYSTEMD_UNIT` required when autoupdate is enabled).
- Push runtime failure handling to user service status and monitoring/alerting, rather than rebuild gating.

Trial outcomes to validate:
- `nixos-rebuild switch` does not stall on persistent `health=starting` containers.
- Auto-update behavior and rollback signals remain clear.
- Preflight script surface can be reduced without losing hard-fail safety where invariants are violated.

Implementation note:
- Phase 1 is now in place: stack deploy uses `compose up -d --remove-orphans` (no compose `--wait` gating).
- Phase 2 is complete: user service is the sole lifecycle owner with native `sops.secrets` wiring and compatibility fallback window.

## Post-Implementation Notes (2026-02-13)

This research is still valid, but the stack implementation has since moved to the simplified Phase 2 model:

1. Startup is bounded to avoid rebuild deadlocks:
   - user compose unit startup is bounded by `startupTimeoutSeconds` (default 300s / 5m).
   - `podman compose` deploy path now uses `up -d --remove-orphans` (no `--wait` gating).
2. Stale-health detection now covers both compose label families:
   - `io.podman.compose.project`
   - `com.docker.compose.project`
3. `StartedAt` parsing was normalized to handle Podman timestamps with zone names (for GNU `date` compatibility).
4. Label-mismatch handling is intentionally hard-fail via container removal before restart so auto-update and systemd ownership stay consistent.
5. User compose unit naming is `${stackName}.service`; `PODMAN_SYSTEMD_UNIT` points there.
6. Legacy `*-stack-secrets.service` orchestration was removed; env files are resolved from native `sops.secrets` paths with one-release fallback support.

### Empirical Update (2026-02-13, `igpu`)

An explicit compose-change propagation test is documented in:
- [restart-probe-compose-change-test-2026-02-13.md](./restart-probe-compose-change-test-2026-02-13.md)

Observed in that test:
- The rebuilt NixOS generation contained the updated user unit and updated compose wrapper path.
- The running user manager continued using a stale unit path from `~/.config/systemd/user`, and restart behavior followed that stale unit definition.
- Once stale home-level unit artifacts were removed, the active unit path switched to `/etc/systemd/user/...` and the updated compose command was applied.

### Incident Confirmation (2026-02-13, AWST)

Production logs later confirmed the predicted failure mode when label invariants are violated:

- `doc1` (`proxmox-vm`) auto-update run: `52` missing-label errors
- `igpu` auto-update run: `13` missing-label errors
- Shared error signature: `no PODMAN_SYSTEMD_UNIT label found`

This validates the need for strict preflight invariant enforcement:

- `io.containers.autoupdate=registry` must always be paired with `PODMAN_SYSTEMD_UNIT`.
- Violations should fail stack startup early, instead of failing during timer-driven auto-update.

Execution test matrix is tracked in:
- `docs/decisions/2026-02-12-container-lifecycle-strategy.md` (`Test Matrix (Invariant Enforcement)`).

## Executive Summary

This document answers critical questions about how `docker-compose --wait` interacts with container reuse, health checks, and the dual service architecture in our podman-compose-based container stack management system. The research reveals that:

1. **Container reuse with `--wait` DOES cause stale health check issues** - this is a real, ongoing risk
2. **Podman auto-update operates independently of compose files** - it works directly with containers via podman API
3. **Control-plane simplification completed in Phase 2** - user service now owns stack lifecycle for both rebuild and auto-update restart targets
4. **Different scenarios require different strategies** - rebuild should optimize for speed, auto-update should prioritize reliability

## Research Questions Answered

### 1. How `--wait` Works: Container Reuse and Health Checks

**Finding:** Docker Compose's `--wait` flag monitors health status but does NOT trigger fresh health checks on reused containers.

#### Key Behavior

From [Docker Compose documentation](https://docs.docker.com/reference/cli/docker/compose/up/):
> "Wait for services to be running|healthy. Implies detached mode."

When `docker-compose up -d --wait` runs:

1. **Container Recreation Decision:** Compose compares the `com.docker.compose.config-hash` label on existing containers against the current compose file configuration ([source](https://deepwiki.com/docker/compose/5.2-config-command))
2. **If Config Unchanged:** Container is reused (not recreated)
3. **Wait Behavior:** `--wait` monitors the CURRENT health status of all services
4. **Critical Issue:** If a reused container has a stuck health check from before, `--wait` waits for that old status to change

#### What Triggers Container Recreation?

From [Docker Compose up documentation](https://docs.docker.com/reference/cli/docker/compose/up/):
> "If there are existing containers for a service, and the service's configuration or image was changed after the container's creation, docker compose up picks up the changes by stopping and recreating the containers (preserving mounted volumes)."

Configuration changes include:
- Image digest (new image version)
- Environment variables
- Port mappings
- Volume mounts
- Network configuration
- Health check definition itself

**Key Finding:** Changing health check parameters in the compose file DOES trigger recreation, but deploying the same config twice (rebuild scenario) reuses containers.

### 2. Stale Health Check Problem: Confirmed Real Risk

**Evidence:** This is a documented issue across the Docker ecosystem.

#### How Containers Get Stuck

From [Last9's Docker Status Unhealthy guide](https://last9.io/blog/docker-status-unhealthy-how-to-fix-it/):
> "The health status is initially 'starting'. Whenever a health check passes, it becomes 'healthy'. After a certain number of consecutive failures, it becomes 'unhealthy'."

From [GitHub issue about stuck health checks](https://github.com/caprover/caprover/issues/844):
> "Container stuck in status (health: starting)" - containers can remain perpetually in "starting" state if the initial health check fails and subsequent restarts reuse the container.

#### The Deadlock Scenario

1. Container starts, application takes too long to initialize
2. First health check runs before app is ready → fails
3. Container shows "Up X minutes (starting)" with failed health log entry
4. Service restarts (nixos-rebuild, manual restart)
5. Docker-compose reuses existing container (config unchanged)
6. `--wait` blocks waiting for health to become "healthy"
7. **Health check system doesn't re-run** (only has the old failed attempt)
8. Deployment hangs indefinitely

From [Docker Community Forums](https://forums.docker.com/t/unhealthy-container-does-not-restart/105822):
> "If the health check command works manually but fails in the health check, the issue is usually timing (runs too early) or environment (missing variables)."

#### Why This Happens

The health check mechanism continues running ONLY if:
- Container was freshly created with health check config
- Health check interval is still actively scheduled

When a container is reused:
- Old health check state persists
- If stuck in "starting" with one failed attempt, no new attempts are scheduled
- Container never transitions to "healthy"
- `--wait` waits forever

### 3. `--force-recreate` Flag: Performance vs Reliability

**Documentation:** From [Docker Compose up command](https://docs.docker.com/reference/cli/docker/compose/up/):
> "To prevent Compose from picking up changes, use the --no-recreate flag."
> "If you want to force Compose to stop and recreate all containers, use the --force-recreate flag."

#### What `--force-recreate` Does

- Stops and removes ALL containers in the stack
- Creates fresh containers even if config hasn't changed
- Resets all health check state
- Similar to Watchtower's always-recreate approach

#### Performance Implications

**For `up -d` (smart reuse):**
- Only recreates changed containers
- Fast for no-op rebuilds
- Preserves container state when possible
- **Risk:** Stale health checks, stuck states

**For `up -d --force-recreate` (always fresh):**
- Recreates everything every time
- Slower (stop + remove + create overhead ~2-5 seconds per container)
- Guaranteed clean slate
- **Safe:** No stale state possible

From community discussions on [force-recreate performance](https://www.howtogeek.com/devops/how-to-make-docker-rebuild-an-image-without-its-cache/):
> "Use `--force-recreate` for situations where you specifically need to ensure a complete rebuild regardless of changes."

### 4. Podman Auto-Update Mechanics: Independent of Compose

**Critical Finding:** Podman auto-update does NOT use compose files. It operates directly on containers via the Podman API.

#### How Podman Auto-Update Works

From [Podman auto-update documentation](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html):
> "To make use of auto updates, the container or Kubernetes workloads must run inside a systemd unit."
>
> "After a successful update of an image, the containers using the image get updated by restarting the systemd units they run in."

Process:
1. Checks registry for image updates (containers with `io.containers.autoupdate=registry` label)
2. Pulls new images if available
3. **Restarts the systemd unit** (not the container directly)
4. Systemd unit recreates containers using the new image

#### The PODMAN_SYSTEMD_UNIT Label

From [GitHub issue #534](https://github.com/containers/podman-compose/issues/534):
> "At container-creation time, Podman looks up the 'PODMAN_SYSTEMD_UNIT' environment variables and stores it verbatim in the container's label."
>
> "A necessary requirement for podman auto-update is that systemd units CREATE the podman container at startup. The systemd units are expected to be generated with podman-generate-systemd --new, or similar units that create new containers in order to run the updated images."

**Key Insight:** Auto-update requires systemd units that **create** containers, not just start/stop them. This is why we have user services.

#### Rollback on Failure

From [Red Hat's Podman auto-update blog](https://www.redhat.com/en/blog/podman-auto-updates-rollbacks):
> "When restarting a systemd unit after updating the image has failed, Podman can rollback to using the previous image and restart the unit. This is enabled by default."

From [GitHub discussion #16098](https://github.com/containers/podman/discussions/16098):
> "With the --sdnotify=container implementation, Podman can support simple rollbacks. Health-checks that fail immediately after start will presumably cause the RestartUnit call to return failed, and therefore have a rollback take effect."

**Rollback Detection:** Podman watches for:
- Systemd unit restart failure
- Container exits with non-zero code
- Health check fails immediately after update (when `on-failure` action is set)

### 5. Dual Service Architecture: Purpose and Relationship

**From our implementation** (`stacks/lib/podman-compose.nix` and `modules/nixos/homelab/containers/default.nix`):

#### System Service: `<stack-name>-stack.service`

**Purpose:** NixOS-rebuild integration (apply configuration changes)

Location: Lines 192-232 in `stacks/lib/podman-compose.nix`

Key characteristics:
- Type: `oneshot` with `RemainAfterExit=true`
- Runs as: `${user}` (rootless)
- Environment: Connects to user's podman socket via `CONTAINER_HOST=unix:///run/user/${userUid}/podman/podman.sock`
- ExecStart: `docker-compose up -d --wait --remove-orphans`
- RestartTriggers: Compose file, sops secrets, custom triggers
- **Used by:** `nixos-rebuild switch` (via systemd activation)

Pre-start checks (line 217):
1. Prune legacy pod_ containers
2. Recreate containers if `PODMAN_SYSTEMD_UNIT` label mismatches (prevents auto-update confusion)
3. Decrypt secrets, set permissions

#### User Service: `podman-compose@<projectName>.service`

**Purpose:** Podman auto-update integration (pull new images, recreate containers)

Location: Lines 234-247 in `stacks/lib/podman-compose.nix`

Key characteristics:
- Type: `oneshot` with `RemainAfterExit=true`
- Runs as: Current user (user service context)
- Environment: Same as system service, includes `PODMAN_SYSTEMD_UNIT=podman-compose@<projectName>.service`
- ExecStart: `docker-compose up -d --wait --remove-orphans`
- RestartIfChanged: `false` (doesn't restart on config changes)
- **Used by:** `podman auto-update` command (systemd restarts this unit when images update)

#### The Relationship

```
nixos-rebuild switch → system service → docker-compose up (smart reuse, fast)
                          ↓
                    Sets PODMAN_SYSTEMD_UNIT=podman-compose@X.service on containers
                          ↓
podman auto-update → Checks registry for new images
                          ↓
                    Finds containers labeled: io.containers.autoupdate=registry
                                            + PODMAN_SYSTEMD_UNIT=podman-compose@X.service
                          ↓
                    Restarts user service → docker-compose up (creates fresh containers with new image)
```

**Key Insight:** Both services use the same compose file and same flags, but they're triggered by different mechanisms:
- System service: Triggered by NixOS activation (config changes)
- User service: Triggered by podman auto-update (image updates)

### 6. Current Implementation Analysis

From `modules/nixos/homelab/containers/default.nix` (lines 249-265):

```nix
podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
  description = "Podman auto-update (rootless)";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = ["" autoUpdateScript];  # Overrides base service
    User = user;
    Environment = [...];
  };
};
```

The `autoUpdateScript` (lines 33-100):
1. Runs `podman auto-update` (NOT docker-compose)
2. Parses output to find updated containers
3. Waits 30 seconds for containers to settle
4. Checks for failures:
   - Container not running (crashed)
   - Container rolled back (dry-run shows still pending update)
5. Sends Gotify notification on failure

**Critical Finding:** Our auto-update does NOT call docker-compose directly. It uses `podman auto-update`, which then triggers systemd to restart the user services, which then run docker-compose.

### 7. Container Reuse: Summary

**Intended behavior** (see section 1 for details):
- Reuse: Config hash matches + same image digest
- Recreate: Config changes, new image, or `--force-recreate`

**Known issue:** Docker Compose v2 sometimes recreates unnecessarily ([GitHub #9600](https://github.com/docker/compose/issues/9600)), but generally respects config hash comparison.

### 8. Best Practices from the Field

#### Health Check Configuration

From [Tom Vaidyan's 2025 guide](https://www.tvaidyan.com/2025/02/13/health-checks-in-docker-compose-a-practical-guide/):

Best practices:
1. **Always add health checks to databases** - They take time to initialize
2. **Use start_period** - Give services time to initialize before checking (default 0s is often too aggressive)
3. **Make health checks lightweight** - They run frequently (default every 30s)
4. **Check actual readiness, not just process existence**

Example configuration:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 40s  # Critical for slow-starting apps
```

#### Watchtower's Pattern

From [Watchtower usage overview](https://containrrr.dev/watchtower/usage-overview/):
> "If watchtower detects that an image has changed, it will automatically restart the container using the new image."
>
> "Watchtower downloads all the latest images locally and gracefully shuts down all the corresponding containers that need the update, then starts them back up using the new Docker base image."

**Key insight:** Watchtower ALWAYS recreates containers on update (no reuse logic). This approach:
- Simpler logic (no convergence complexity)
- Guaranteed clean state
- Slightly slower but more reliable
- Worked reliably for years across thousands of deployments

## Synthesis: Answering the Core Questions

### Q1: Does Container Reuse Cause Stale Health Checks with `--wait`?

**Answer:** YES, definitively.

When `docker-compose up -d --wait` reuses an existing container:
1. The container's health check state persists from before
2. If that state is stuck (e.g., perpetual "starting"), it never changes
3. `--wait` blocks indefinitely waiting for "healthy" status
4. No new health checks are triggered (old state persists)

**Evidence:**
- [Docker community forums](https://forums.docker.com/t/unhealthy-container-does-not-restart/105822) document this pattern
- [GitHub issues](https://github.com/caprover/caprover/issues/844) show containers stuck in "starting" state
- Our own experience (bead nixosconfig-hbz) confirms this happens in production

### Q2: Should We Use Different Flags for Rebuild vs Auto-Update?

**Answer:** NO - the dual service architecture already handles this correctly (see section 5 for details).

**For Rebuild (system service):**
- Smart reuse via `docker-compose up -d --wait` (fast, incremental)
- Mitigation: `recreateIfLabelMismatch` + proposed stale health detection

**For Auto-Update (user service):**
- Full recreation via systemd restart cycle (ExecStop → ExecStart)
- Built-in rollback protection from podman auto-update

### Q3: What Is the Root Cause of Stale Container Issues?

**Answer:** Container reuse during nixos-rebuild when health checks are in a bad state.

**Scenario:**
1. Service deployed initially, containers healthy
2. Something breaks (network issue, dependency failure, resource exhaustion)
3. Container health check fails, stuck in "starting" or "unhealthy"
4. User runs `nixos-rebuild switch` (config unchanged, maybe just updating other hosts)
5. System service runs: `docker-compose up -d --wait`
6. Container reused (config hash matches)
7. `--wait` blocks on stale health check
8. Deployment hangs

**Current Mitigations:**
1. `stackCleanup` script (line 40-64) prunes stopped containers after each operation
2. `recreateIfLabelMismatch` (line 173) removes containers with wrong unit labels
3. Manual intervention: `podman rm -f <name>` when stuck

**Gap:** No automatic detection of stuck health checks BEFORE attempting reuse.

## Recommendations

### Recommendation 1: Add Stale Health Check Detection (HIGH PRIORITY)

**Problem:** Container reuse can inherit stuck health check state, causing indefinite hangs.

**Solution:** Add pre-start check in system service to detect and remove containers with stale health:

```nix
# In stacks/lib/podman-compose.nix, add parameter:
healthCheckTimeout ? 90  # Default 90 seconds, configurable per-stack

# Add to ExecStartPre:
detectStaleHealth = [
  ''
    /run/current-system/sw/bin/sh -c '
      ids=$(${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format "{{.ID}}")
      for id in $ids; do
        health=$(${podmanBin} inspect -f "{{.State.Health.Status}}" $id 2>/dev/null || echo "none")
        started=$(${podmanBin} inspect -f "{{.State.StartedAt}}" $id 2>/dev/null)

        # Only remove if unhealthy/starting AND running for >threshold
        if [ "$health" = "starting" ] || [ "$health" = "unhealthy" ]; then
          age_seconds=$(( $(date +%s) - $(date -d "$started" +%s) ))
          if [ $age_seconds -gt ${toString healthCheckTimeout} ]; then
            echo "Removing container $id with stale health ($health) - running for ${age_seconds}s (threshold: ${toString healthCheckTimeout}s)"
            ${podmanBin} rm -f $id
          else
            echo "Container $id is $health but only ${age_seconds}s old - allowing more time (threshold: ${toString healthCheckTimeout}s)"
          fi
        fi
      done
    '
  ''
];
```

Add this to line 217 (before recreateIfLabelMismatch).

**Edge Case Handling:**
- **Default 90 seconds:** Covers most services (2-3x typical 30-45s startup time)
- **Rapid rebuilds safe:** Won't get stuck in multi-minute loops during development
- **Configurable per-stack:** Slow services can override (e.g., `healthCheckTimeout = 300` for database migrations)
- **Formula:** Set to 2-3x expected startup time for the slowest container in the stack

**Benefits:**
- Prevents indefinite hangs during rebuild (90s max wait for stuck containers)
- Safe for rapid rebuilds during development (won't loop for 5+ minutes)
- Maintains fast reuse for healthy containers
- Automatic remediation (no manual intervention)
- Low overhead (quick inspect check)
- Configurable per-stack for edge cases

**Testing Strategy:** See Testing section below.

### Recommendation 2: Improve Health Check Configuration Guidance (MEDIUM PRIORITY)

**Problem:** Many containers lack proper `start_period` configuration, leading to premature health check failures.

**Solution:** Document health check best practices in stack templates:

```yaml
# Template in docs/stack-template.yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost/health"]
  interval: 30s        # How often to check after start_period
  timeout: 10s         # How long to wait for response
  retries: 3           # Consecutive failures before "unhealthy"
  start_period: 60s    # Grace period for slow startup (CRITICAL)
```

**Best Practices to Document:**
- Always include `start_period` for apps with initialization time
- Use 2-3x expected startup time for `start_period`
- Keep interval reasonable (30s default is good)
- Avoid expensive health checks (they run every interval)
- Test health check command manually before deploying

### Recommendation 3: Keep Current Dual Service Architecture (NO CHANGE)

**Problem:** Initial concern about dual services being confusing or redundant.

**Finding:** The architecture is actually elegant and serves distinct purposes:

```
System Service (oneshot):
  - Triggered by: nixos-rebuild switch
  - Purpose: Apply config changes incrementally
  - Strategy: Smart reuse (fast, only restart changed containers)
  - Protection: Stale health detection (recommendation 1)

User Service (oneshot):
  - Triggered by: podman auto-update (via systemd restart)
  - Purpose: Pull new images, deploy updates
  - Strategy: Full recreation (systemd stop → start cycle)
  - Protection: Built-in rollback (podman auto-update feature)
```

**Recommendation:** Keep both services as-is. They already implement the right strategies for their use cases.

### Recommendation 4: Do NOT Add `--force-recreate` to System Service (AVOID)

**Temptation:** Always use `--force-recreate` to avoid stale state issues.

**Why NOT to do this:**
- Defeats purpose of incremental config changes
- Unnecessarily restarts ALL containers on every rebuild
- Slower deployments (2-5s overhead per container)
- Causes downtime when only secrets/firewall rules changed
- Loses NixOS activation optimization

**Better approach:** Fix the root cause (recommendation 1) rather than work around it.

### Recommendation 5: Monitor Health Check Performance (LOW PRIORITY)

**Problem:** We don't have visibility into health check timing and failure patterns.

**Solution:** Add logging to track health check state transitions during deployments:

```nix
# In ExecStartPre, before docker-compose up:
logHealthStatus = [
  "/run/current-system/sw/bin/sh -c '${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format \"{{.Names}}: {{.Status}}\" | /run/current-system/sw/bin/tee /tmp/podman-health-pre-${projectName}.log || true'"
];

# In ExecStartPost, after docker-compose up:
logHealthStatusPost = [
  "/run/current-system/sw/bin/sh -c '${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format \"{{.Names}}: {{.Status}}\" | /run/current-system/sw/bin/tee /tmp/podman-health-post-${projectName}.log || true'"
];
```

**Benefits:**
- Historical record of health check patterns
- Can identify containers that frequently get stuck
- Helps tune `start_period` and `interval` settings
- Useful for debugging deployment issues

## Testing Strategy

### Testing Recommendation 1 (Stale Health Detection)

**Goal:** Verify the detection script correctly identifies and removes stuck containers without breaking healthy ones.

#### Phase 1: Validation in Dev Environment

1. **Test Setup:**
   ```bash
   # On dev VM, create a test stack with intentionally broken health check
   cat > /tmp/test-health-compose.yml <<EOF
   services:
     test-slow:
       image: nginx:alpine
       healthcheck:
         test: ["CMD", "sleep", "999"]  # Always times out
         interval: 30s
         timeout: 10s
         start_period: 10s
     test-healthy:
       image: nginx:alpine
       healthcheck:
         test: ["CMD", "curl", "-f", "http://localhost"]
         interval: 30s
         timeout: 5s
   EOF

   podman compose -f /tmp/test-health-compose.yml up -d
   ```

2. **Wait for stuck state:**
   ```bash
   # Wait 2+ minutes for test-slow to get stuck in "starting"
   watch 'podman ps -a --format "{{.Names}}: {{.Status}}"'
   ```

3. **Test detection script:**
   ```bash
   # Run the detection logic manually (using 90s threshold)
   threshold=90
   ids=$(podman ps -a --filter label=io.podman.compose.project=tmp --format "{{.ID}}")
   for id in $ids; do
     health=$(podman inspect -f "{{.State.Health.Status}}" $id 2>/dev/null || echo "none")
     started=$(podman inspect -f "{{.State.StartedAt}}" $id 2>/dev/null)
     age_seconds=$(( $(date +%s) - $(date -d "$started" +%s) ))
     echo "Container $id: health=$health, age=${age_seconds}s"

     if [ "$health" = "starting" ] || [ "$health" = "unhealthy" ]; then
       if [ $age_seconds -gt $threshold ]; then
         echo "  → Would remove (stale, age > ${threshold}s)"
       else
         echo "  → Keeping (still initializing, age < ${threshold}s)"
       fi
     fi
   done
   ```

4. **Expected results:**
   - `test-slow` (>90s, "starting") → marked for removal
   - `test-healthy` ("healthy") → not touched
   - If `test-slow` is <90s old → kept (wait longer)

#### Phase 2: Safe Rollout to Production

1. **Add detection to ONE stack first:**
   ```nix
   # In stacks/management/docker-compose.nix (small, non-critical stack)
   # Add detectStaleHealth to ExecStartPre
   ```

2. **Deploy and monitor:**
   ```bash
   # On doc1
   sudo nixos-rebuild switch --flake .#proxmox-vm
   journalctl -u management-stack.service -f
   ```

3. **Verify behavior:**
   - Check logs for "Removing container..." messages
   - Confirm removed containers were actually stuck
   - Verify healthy containers weren't touched

4. **Gradual expansion:**
   - Week 1: 1-2 small stacks (management, domain-monitor)
   - Week 2: Medium stacks (paperless, mealie)
   - Week 3: Critical stacks (immich, caddy)

#### Phase 3: Rollback Plan

**If detection removes wrong containers:**

1. **Immediate rollback:**
   ```bash
   # Revert to previous generation
   sudo nixos-rebuild switch --rollback
   ```

2. **Manual recovery:**
   ```bash
   # Recreate affected stack
   cd /mnt/docker/<stack-name>
   podman compose up -d
   ```

3. **Adjust threshold:**
   ```nix
   # Increase from 300s to 600s (10 minutes) if legitimately slow
   if [ $age_seconds -gt 600 ]; then
   ```

**Safety guarantees:**
- Only affects containers already in bad health states
- Won't touch "healthy" or "none" (no health check) containers
- Time threshold prevents premature removal
- Worst case: Container recreated (same as manual fix)

### Testing Recommendation 2 (Health Check Guidance)

**Validation:**
1. Test health check templates in sandbox
2. Verify `start_period` covers actual initialization time
3. Confirm health check command runs successfully

### Monitoring During Rollout

**What to watch:**
```bash
# Track health state changes
journalctl -u '*-stack.service' | grep -E '(stale health|Removing container)'

# Monitor auto-update behavior
journalctl -u podman-auto-update.service

# Check for unexpected restarts
podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
```

## Implementation Priority

1. **HIGH:** Stale health check detection (Recommendation 1)
   - Solves immediate pain point (deployments hanging)
   - Low risk with proper testing (phase 1-3 above)
   - Quick to implement (~20 lines in podman-compose.nix)

2. **MEDIUM:** Health check configuration guidance (Recommendation 2)
   - Prevents future issues
   - Requires documentation effort
   - Improves long-term reliability

3. **LOW:** Health check monitoring (Recommendation 5)
   - Nice to have for debugging
   - Can be added incrementally
   - Not urgent (works fine without it)

## Conclusion

The open question about rebuild vs auto-update behavior has been answered:

1. **Container reuse IS the problem** - stale health checks cause real deployment hangs
2. **Different scenarios already use different strategies** - system service reuses, user service recreates
3. **The dual service architecture is correct** - each service optimized for its use case
4. **Solution is targeted remediation** - detect and remove stale containers before reuse, not blanket --force-recreate

**Next Steps:**
1. Implement stale health check detection (Recommendation 1)
2. Update documentation with health check best practices (Recommendation 2)
3. Close research bead (nixosconfig-cm5) with findings
4. Update bug bead (nixosconfig-hbz) with remediation plan

## References

### Official Documentation
- [Docker Compose up command](https://docs.docker.com/reference/cli/docker/compose/up/)
- [Docker Compose startup order](https://docs.docker.com/compose/how-tos/startup-order/)
- [Podman auto-update documentation](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html)
- [Red Hat: Podman auto-updates and rollbacks](https://www.redhat.com/en/blog/podman-auto-updates-rollbacks)

### Community Resources
- [Last9: Docker Compose Health Checks](https://last9.io/blog/docker-compose-health-checks/)
- [Last9: Docker Status Unhealthy](https://last9.io/blog/docker-status-unhealthy-how-to-fix-it/)
- [Tom Vaidyan: Health Checks Guide (2025)](https://www.tvaidyan.com/2025/02/13/health-checks-in-docker-compose-a-practical-guide/)
- [Maciej Walkowiak: Docker Compose Waiting](https://maciejwalkowiak.com/blog/docker-compose-waiting-containers-ready/)
- [Watchtower Usage Overview](https://containrrr.dev/watchtower/usage-overview/)

### GitHub Issues and Discussions
- [docker/compose#8351: --wait flag feature request](https://github.com/docker/compose/issues/8351)
- [docker/compose#9600: Unnecessary recreation bug](https://github.com/docker/compose/issues/9600)
- [docker/compose#10068: Container re-created when it shouldn't](https://github.com/docker/compose/issues/10068)
- [podman#534: Autoupdate with podman-compose](https://github.com/containers/podman-compose/issues/534)
- [podman#16098: Clarifying auto-update and rollback](https://github.com/containers/podman/discussions/16098)
- [caprover#844: Container stuck in starting state](https://github.com/caprover/caprover/issues/844)

### Forum Discussions
- [Docker Forums: up --wait behavior changed](https://forums.docker.com/t/behavior-of-up-wait-changed/147699)
- [Docker Forums: Unhealthy container does not restart](https://forums.docker.com/t/unhealthy-container-does-not-restart/105822)
- [Docker Forums: Recreates every time (solved)](https://forums.docker.com/t/solved-docker-compose-up-recreates-every-time/134733)
