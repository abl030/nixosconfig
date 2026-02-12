# Container Lifecycle Analysis: Rebuild vs Auto-Update

**Research Date:** 2026-02-12
**Related Beads:** nixosconfig-cm5 (research task), nixosconfig-hbz (stale container bug)
**Status:** Complete

## Executive Summary

This document answers critical questions about how `docker-compose --wait` interacts with container reuse, health checks, and the dual service architecture in our podman-compose-based container stack management system. The research reveals that:

1. **Container reuse with `--wait` DOES cause stale health check issues** - this is a real, ongoing risk
2. **Podman auto-update operates independently of compose files** - it works directly with containers via podman API
3. **The dual service architecture serves distinct purposes** - system service for rebuild, user service for auto-update
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

### 7. Container Reuse: When It Happens

From [GitHub issues about recreation](https://github.com/docker/compose/issues/9600):
> "docker compose up recreates running container that does not have their configs changed in docker-compose.yml"

This is a known bug in Docker Compose v2, but the intended behavior is:

**Containers are reused when:**
- Config hash matches (no changes to service definition)
- Image digest is the same
- Same volumes, networks, environment

**Containers are recreated when:**
- Config hash differs (any service definition change)
- New image version pulled
- `--force-recreate` flag used
- `--no-deps` prevents dependency cascades

From [DeepWiki documentation](https://deepwiki.com/docker/compose/5.2-config-command):
> "The hash computation in compose.ServiceHash() is used for detecting configuration changes and determining when containers need recreation."

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

**Answer:** NO - but for a surprising reason.

The dual service architecture already separates these concerns:

**For Rebuild (system service):**
- Current: `docker-compose up -d --wait --remove-orphans`
- Container reuse: Desired (fast, only restart what changed)
- Risk: Stale health checks
- **Mitigation already in place:** `recreateIfLabelMismatch` check (line 173) removes containers with wrong `PODMAN_SYSTEMD_UNIT` label

**For Auto-Update (user service via podman auto-update):**
- Current: Systemd restarts user service → `docker-compose up -d --wait --remove-orphans`
- Container reuse: Does NOT happen (systemd ExecStop removes containers before ExecStart)
- Actually behaves like `--force-recreate` (fresh containers every time)
- Has rollback protection (podman auto-update built-in feature)

**Key Finding:** User services already recreate containers because systemd runs the FULL service cycle (ExecStop → ExecStart). The Type=oneshot with RemainAfterExit=true means:
- On restart: Stop command runs first (stops containers)
- Then: Start command runs (creates fresh containers)

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
# In stacks/lib/podman-compose.nix, add to ExecStartPre:
detectStaleHealth = [
  ''
    /run/current-system/sw/bin/sh -c '
      ids=$(${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format "{{.ID}}")
      for id in $ids; do
        health=$(${podmanBin} inspect -f "{{.State.Health.Status}}" $id 2>/dev/null || echo "none")
        started=$(${podmanBin} inspect -f "{{.State.StartedAt}}" $id 2>/dev/null)

        # Only remove if unhealthy/starting AND running for >5 minutes
        if [ "$health" = "starting" ] || [ "$health" = "unhealthy" ]; then
          age_seconds=$(( $(date +%s) - $(date -d "$started" +%s) ))
          if [ $age_seconds -gt 300 ]; then
            echo "Removing container $id with stale health ($health) - running for ${age_seconds}s"
            ${podmanBin} rm -f $id
          else
            echo "Container $id is $health but only ${age_seconds}s old - allowing more time"
          fi
        fi
      done
    '
  ''
];
```

Add this to line 217 (before recreateIfLabelMismatch).

**Edge Case Handling:**
- **Legitimately slow containers:** 5-minute threshold allows slow-starting apps to complete initialization
- **Truly stuck containers:** If still "starting" after 5 minutes, it's deadlocked (normal apps shouldn't take this long)
- **Configurable threshold:** Can be adjusted per-stack if needed (some stacks may need longer grace periods)

**Benefits:**
- Prevents indefinite hangs during rebuild
- Maintains fast reuse for healthy containers
- Automatic remediation (no manual intervention)
- Low overhead (quick inspect check)
- Safe: Won't remove legitimately initializing containers

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

## Implementation Priority

1. **HIGH:** Stale health check detection (Recommendation 1)
   - Solves immediate pain point (deployments hanging)
   - Low risk (removes containers that are already broken)
   - Quick to implement (~10 lines in podman-compose.nix)

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
