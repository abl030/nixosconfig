# Beads Archive

Final snapshot of the beads issue tracker before removal (see GitHub issue #205).
Tracked 84 total issues in the nixosconfig repo from 2026-02-24 to 2026-04-14.
Future work is tracked in GitHub issues.

## nixosconfig-6x4 — Podman Rootless Operations Tracker

- **Status:** open
- **Type:** epic
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Track current rootless Podman compose operating model, accepted residual risks, and future migration options (Quadlet and native Nix orchestration).

### Notes

2026-02-24 incident: music stack went down after a compose file change (slskd/cratedigger commented out) triggered a service restart. compose stop left containers in Exited state; compose up then failed because the old network-holder pod still had dependent containers registered against it, so docker-compose couldn't recreate the pod. The ExecStartPre recreate-if-label-mismatch script only removed containers with a PODMAN_SYSTEMD_UNIT label mismatch — correctly-labelled Exited containers were untouched. Fix (untested): extended the script to also rm -f --depend all exited/created/dead containers for the project before compose up, giving it a clean slate. All persistent state is in volumes so this is safe.

---

## nixosconfig-3dj — Evaluate Quadlet migration path for high-value stacks

- **Status:** open
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Define incremental canary-based migration approach from compose-managed stacks to Quadlet with explicit rollback criteria.

---

## nixosconfig-8u7 — Evaluate native Nix container orchestration options

- **Status:** open
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Survey viable Nix-native orchestration patterns for homelab stacks and compare operational tradeoffs against current compose model.

---

## nixosconfig-uid — Migrate domain-monitor to mkService pattern

- **Status:** open
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Migrate domain-monitor stack from custom service definition to use mkService abstraction.

Current custom behaviors to preserve:
- Build context copying to /tmp
- Docker build integration (--build flag)
- Separate cron service/timer for domain checking
- Custom directory structure

This should be done AFTER Phase 2 is stable on both hosts.

File: stacks/domain-monitor/docker-compose.nix

Blocked by: Phase 2 completion and stabilization

---

## nixosconfig-0gs — Research episodic memory options (3+ candidates)

- **Status:** closed
- **Type:** task
- **Priority:** 1
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Compare at least 3 episodic memory solutions for Claude Code. Produce docs/episodic-memory-comparison.md with architecture, pros/cons, NixOS packaging difficulty, and recommendation. Converge on one to implement.

---

## nixosconfig-9nt — Phase 2: Episodic Memory (conversation archive)

- **Status:** closed
- **Type:** epic
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Deploy obra/episodic-memory for cross-session conversation recall. Archives Claude Code conversation JSONL, indexes with local vector embeddings, exposes semantic search via MCP. BLOCKED by upstream bugs: #47 (MCP stdout corruption), #53 (orphaned processes). See docs/agentic-memory-options-comparison.md.

### Notes

2026-02-11: PAUSED. Episodic-memory plugin disabled in base.nix. npm deps require manual install which breaks Nix store, and no credits to justify the plumbing. Flake input kept. Re-evaluate when upstream plugin dep management improves (anthropics/claude-code#13505) or we have credits.

---

## nixosconfig-ats — Research agentic memory landscape

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Evaluate beads, claude-mem, episodic-memory. Document findings in docs/agentic-memory-landscape.md and docs/agentic-memory-options-comparison.md.

---

## nixosconfig-365 — Merge fork back to upstream episodic-memory when PRs land

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

We forked obra/episodic-memory to abl030/episodic-memory and merged PRs #56 (stdout fix, orphan fix, similarity score fix, cross-platform build) and #51 (clear session matcher). Periodically check if upstream merges these PRs. When they do, switch back to upstream and archive the fork. Check: gh pr view 56 --repo obra/episodic-memory --json state && gh pr view 51 --repo obra/episodic-memory --json state

---

## nixosconfig-3re — Research: Container lifecycle analysis (podman compose)

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

# Container Lifecycle Analysis: Rebuild vs Auto-Update

**Research Date:** 2026-02-12
**Related Beads:** nixosconfig-cm5 (research task), nixosconfig-hbz (stale container bug)
**Status:** Complete (implemented and hardened through 2026-02-13; ownership follow-up moved to Phase 2.5)
**Related empirical test:** [2026-02-13-compose-change-propagation-test.md](../incidents/2026-02-13-compose-change-propagation-test.md)

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
7. Ownership follow-up (Phase 2.5) is now tracked separately:
   - `docs/podman/decisions/2026-02-13-home-manager-user-unit-ownership.md`
   - `docs/podman/current/phase2.5-home-manager-migration-plan.md`
   - `docs/podman/research/home-manager-user-service-migration-research-2026-02.md`

### Empirical Update (2026-02-13, `igpu`)

An explicit compose-change propagation test is documented in:
- [2026-02-13-compose-change-propagation-test.md](../incidents/2026-02-13-compose-change-propagation-test.md)

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
- `docs/podman/decisions/2026-02-12-container-lifecycle-strategy.md` (`Test Matrix (Invariant Enforcement)`).

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

---

## nixosconfig-awt — Research: Home Manager user service migration

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

# Architecture and Operations Research on User-Scoped Podman Stack Units

## Executive verdict

Verdict: Partially. Moving your Podman stack lifecycle units from NixOS-generated user units in /etc/systemd/user to Home Manager–generated user units in ~/.config/systemd/user will materially reduce (and, in the common case, eliminate) the specific “stale ~/.config/systemd/user shadowed updated /etc/systemd/user” class of failures because ~/.config/systemd/user sits higher in the systemd user-unit search path than /etc/systemd/user, and the unit loader explicitly states that earlier directories override later ones.

However, this migration does not inherently guarantee rebuild-time restart/reconciliation for user-scoped services because Home Manager’s activation logic will only perform systemd reload/switch operations when the user systemd manager is reachable (it checks systemctl --user is-system-running and skips if not running). This means failures still occur when the user manager is absent/non-lingering/unreachable, and some drift/override failure modes just “move” from /etc↔~/.config precedence conflicts into drop-in overrides / user-manager availability / sd-switch behavior.

In other words: Home Manager is a strong mitigation for your observed incident and improves lifecycle handling when the user manager is healthy, but it is not a universal fix for all reconciliation failures while staying in user scope.

## Evidence by failure mode

### Failure mode: unit file shadowing across /etc/systemd/user and ~/.config/systemd/user

Observed incident (repo fact): stale unit under ~/.config/systemd/user/... shadowed the updated unit under /etc/systemd/user/..., leading to unexpected behavior after systemctl --user daemon-reload && restart.

What systemd actually guarantees (primary sources):

- The systemd.unit(5) user-unit search path lists (among others) both ~/.config/systemd/user and /etc/systemd/user, and the manual is explicit about precedence: “files found in directories listed earlier override files with the same name in directories lower in the list.”

This means that as long as a stale unit file continues to exist in ~/.config/systemd/user, it will override the unit of the same name in /etc/systemd/user, regardless of what you do to the /etc copy.

Why daemon-reload + restart didn’t “fix” it:

- systemctl daemon-reload reloads the systemd manager configuration, reruns generators, reloads unit files, and recreates the dependency tree. It does not promise to change which on-disk file is selected if the load-path precedence and the set of files hasn’t changed.
- systemctl restart promises “stop and then start” for the unit. It does not promise to flush all resources or to “discover a different unit file from a lower-precedence directory.”

So, with precedence unchanged, daemon-reload will reload the unit definition from the highest-precedence location (the stale ~/.config/... copy), and restart will restart that same loaded definition. This exactly matches your “expected new behavior did not appear” symptom and is fully consistent with documented precedence rules.

### Failure mode: “restart” is not a full “reconcile” primitive

Two separate limitations matter operationally:

- systemctl reload is explicitly “service-specific configuration” reload and not unit-file reload; unit-file reload requires daemon-reload.
- systemctl restart does not necessarily flush all unit resources; if you need full resource teardown you may need stop followed by start.

For container stacks, this matters because a “restart” may not guarantee that everything you care about (environment, ExecStart semantics, dependency ordering, or other resource state) is re-derived if the unit definition you actually intended to load is not the one systemd is using, or if your unit semantics rely on full stop/start behavior.

### Failure mode: shadowing can also come from higher-precedence runtime/control paths

Your question focused on 4 paths, but the real top-of-path items in user scope include “control” and runtime directories, e.g. ~/.config/systemd/user.control and $XDG_RUNTIME_DIR/systemd/user.control, as well as transient and generator directories.

Operational implication: if some tool writes persistent user-manager “control” overrides, or transient units exist with the same name, you can still see “I updated the file but behavior didn’t change” even when you standardize on Home Manager. This is a residual risk category to explicitly test.

### Failure mode: does systemctl --user revert <unit> help in this specific incident?

systemctl revert is defined as “revert … unit files to their vendor versions” and removes drop-in config plus any user-configured unit file that overrides a matching vendor unit (vendor meaning “located below /usr/”). It also notes that if the unit has no vendor-supplied version, it is not removed.

In your incident, the conflict was user config (~/.config/...) overriding admin config (/etc/...), not overriding a vendor unit in /usr/lib/systemd/user or similar. Therefore, systemctl --user revert is not expected to remove the ~/.config/... unit file in order to “fall back” to /etc/systemd/user, because /etc is not “vendor” per the documented definition.

What revert can help with in this general area is removing drop-ins and unmasking—i.e., if the “shadowing” is caused by systemctl --user edit drop-ins or masks rather than a full competing unit file.
But for the specific “~/.config vs /etc” override you described, it should be treated as non-solution / only partially relevant.

## Home Manager impact analysis

### Where Home Manager materializes systemd.user.services

Home Manager’s modules/systemd.nix generates user units into XDG config files under systemd/user/... (e.g. systemd/user/<unit>.service) and installs WantedBy/RequiredBy links under systemd/user/<target>.wants/ etc. This is done via xdg.configFile entries with names like systemd/user/${filename}.

With standard XDG defaults, that means: ~/.config/systemd/user/*.service (and related wants/requires directories) are Home Manager’s primary materialization target for user units.

Home Manager also has an explicit mechanism to expose unit files shipped by packages into $XDG_DATA_HOME/systemd/user, via its systemd.user.packages option.
This matters because the systemd user-unit search path includes both config-home and data-home directories (with config-home taking precedence).

### How Home Manager activation reloads and (attempts to) reconcile services

Home Manager defines an activation step home.activation.reloadSystemd which:

- Ensures XDG_RUNTIME_DIR is set (comment says this is needed when running from the NixOS module where it is not set).
- Checks the user manager state via systemctl --user is-system-running. It proceeds only if the result is running or degraded; otherwise it prints “User systemd daemon not running. Skipping reload.”
- When enabled, it uses sd-switch to compute differences between “old units directory” and “new units directory” (derived from the old/new Home Manager generations) and automatically applies the necessary start/stop/reload/restart actions.
- When systemd.user.startServices is disabled, it instead runs a script that only prints suggested systemctl commands, requiring manual application.

Home Manager also introduces unit-level metadata for switching behavior (in the unit’s [Unit] section): X-Reload-Triggers, X-Restart-Triggers, and X-SwitchMethod (e.g., “reload”, “restart”, “stop-start”, “keep-old”). These are explicitly described as activation-time triggers/switch hints.

### How Home Manager behaves standalone vs NixOS integration

The Home Manager project documents that it can be used standalone or “as a module within a NixOS system configuration,” where user profiles are built together with the system when running nixos-rebuild.

In NixOS integration, Home Manager creates a system-level oneshot service per configured user: home-manager-<username>.service, which runs as that user (User=<username>), is ordered into multi-user.target, and executes the Home Manager activation package.

That system service runs the activation script using a login shell and attempts to import session variables from the user’s systemd environment via systemctl --user show-environment, while also defaulting XDG_RUNTIME_DIR to /run/user/$UID if unset.

Important implication for your objective: Under NixOS integration, Home Manager activation is not “magically more privileged”—it still ultimately depends on being able to talk to the user systemd manager. Home Manager’s own activation code explicitly anticipates that XDG_RUNTIME_DIR could be missing under the NixOS module and patches around it, but it still skips reloading if the user manager is not reachable/running.

### Would Home Manager ownership eliminate the specific shadowing class?

Yes, for the class you observed—if you consolidate ownership.

Your incident is a cross-owner collision: NixOS-generated user units are placed under /etc/systemd/user (via environment.etc."systemd/user") , but ~/.config/systemd/user has higher precedence.

If you move generation of those units into Home Manager, the authoritative units move into the highest-precedence directory (~/.config/systemd/user), which makes “stale ~/.config shadowed updated /etc” structurally unlikely—because there is no longer a need for an /etc copy at all, and Home Manager will overwrite/update the ~/.config copy each activation.

But it can “move” the failure mode:

- Overrides and drop-ins created by systemctl --user edit live in user config scope and can still override what Home Manager writes. (systemctl revert only guarantees vendor reversion semantics, not “revert to Home Manager version.”)
- Home Manager only attempts service reconciliation when the user manager is running or degraded; otherwise it will skip.

So, you eliminate one precedence collision class, but you must still manage drift/overrides and user-manager availability.

## Test system blueprint

This blueprint is designed to validate both ownership models while being edge-case heavy and automation-friendly:

- Model A: NixOS-generated user units in /etc/systemd/user (current design).
- Model B: Home Manager–generated user units in ~/.config/systemd/user with systemd.user.startServices active (candidate design).

### Persistent test host path

Goal: a “prod-like” environment where state (including drift, stale links, and rollbacks) can accumulate.

Recommended shape

A dedicated VM (or spare host) with:

- Your flake-based system config and Home Manager integration enabled (repo fact).
- A dedicated test user that owns the Podman rootless stack units (so you can isolate failures).
- Persistent storage backing (qcow2 + snapshots, or ZFS dataset) so you can force “stale generation” behavior and test rollback semantics.

Observability baseline (capture every run)

Use these as your invariant “before/after” checks:

```bash
# Identify which unit file systemd is actually using
systemctl --user show <unit> -p FragmentPath -p DropInPaths -p UnitFileState

# Show the on-disk unit content (helps detect shadowing & diverged edits)
systemctl --user cat <unit>

# Confirm unit-path precedence on *this* host (diagnose surprises)
systemd-analyze --user unit-paths || true

# Global user-manager state
systemctl --user is-system-running
systemctl --user --failed --no-pager

# Podman state
podman ps --all
podman images
podman inspect <container> --format '{{.State.Status}} {{.State.Health.Status}}' 2>/dev/null || true

# Journal slice around the rebuild (tune time window per run)
journalctl --user -u <unit> --no-pager -b
```

The critical invariant you want per scenario is: FragmentPath points where you think it does, and the observed running containers match the intended generation.

### Fast repeatable harness path

Goal: dozens of scenarios, repeatable, minimal manual setup.

Two practical approaches (choose based on your tolerance for build time vs fidelity):

Harness option: NixOS VM test framework (highest rigor, heavier builds)
Use NixOS’ VM test system (the same style as nixosTests) to boot a VM, apply two generations, and assert systemd + Podman behavior via scripted commands. This is the most “programmable scenario runner” style because the test driver can intentionally corrupt files, simulate missing runtime dirs, and run rebuild/rollback sequences deterministically.

Harness option: QEMU VM with snapshot + scenario runner (fast iteration, high fidelity)
Build a single VM once, then run scenarios by:

- Snapshot baseline.
- Apply scenario mutations (compose/env/secret/unit drift).
- Run nixos-rebuild switch (or direct switch-to-configuration) and record assertions.
- Roll back snapshot.

This preserves “real” systemd and Podman behavior without re-building the world per test.

### Scenario runbook definitions

The scenarios below are written to be applicable to both Model A and Model B; the key is what you declare as the “expected FragmentPath”:

- Model A expected FragmentPath: /etc/systemd/user/<unit> (or a symlink under /etc/systemd/user).
- Model B expected FragmentPath: ~/.config/systemd/user/<unit> (or a symlink there).

For each scenario, “Assertions” include both systemd and Podman state checks.

S01 — Unit shadowing conflict (~/.config vs /etc)

Setup
Create two different unit files with the same name and obvious behavioral differences:

- A copy under ~/.config/systemd/user/<unit>.service
- A copy under /etc/systemd/user/<unit>.service

(You can do this by temporarily disabling your generator and writing minimal test units.)

Action

```bash
systemctl --user daemon-reload
systemctl --user restart <unit>
```

Assertions

```bash
systemctl --user show <unit> -p FragmentPath
systemctl --user cat <unit> | head
```

Expected: FragmentPath resolves to the user config copy, because earlier directories override later ones in the user unit search path.

Pass/fail criteria
Pass if the active unit source is the higher-precedence path and behavior matches that file; fail otherwise.

Cleanup
Remove the manually created unit file(s) and reload.

S02 — “daemon-reload does not unshadow”

Setup
Same as S01.

Action
Modify only the /etc/systemd/user copy; leave ~/.config copy untouched. Then:

```bash
systemctl --user daemon-reload
systemctl --user restart <unit>
```

Assertions
FragmentPath and cat still point to ~/.config copy, not the updated /etc copy, until the higher-precedence file is removed. (Pass if you observe that “reload + restart” doesn’t switch to lower-precedence file.)

Cleanup
Remove test units.

S03 — Compose change: image tag change

Setup
Baseline stack running from a compose file with a pinned image tag.

Action
Change tag (e.g., myimage:v1 → myimage:v2) and rebuild/switch.

Assertions

```bash
systemctl --user status <unit> --no-pager
podman ps --all --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

Expected: service returns to active, container image matches new tag, and restart occurred.

Pass/fail criteria
Pass if container restarts into new image and unit remains active; fail if container remains on old image or unit uses old ExecStart.

Cleanup
Rollback commit or revert tag.

S04 — Compose change: service rename (forces remove/create)

Setup
Compose file with service web.

Action
Rename service to web2 and rebuild/switch.

Assertions

```bash
podman ps -a --format '{{.Names}}'
systemctl --user status <unit> --no-pager
```

Expected: old container removed or stopped; new named container exists; unit active.

Pass/fail criteria
Pass if “rename” produces correct container set without leaving orphaned (unless explicitly desired).

Cleanup
Revert.

S05 — Environment file missing vs removed vs malformed

Setup
Unit references an EnvironmentFile (directly or via script). Start in “present & valid” state.

Action A (missing)
Delete the env file, rebuild/switch.

Assertions

```bash
systemctl --user status <unit> --no-pager
journalctl --user -u <unit> --no-pager -b | tail -n 80
```

Expected: service fails deterministically and logs indicate missing file / parse failure.

Action B (removed from config)
Remove reference from stack definition, rebuild/switch.

Assertions
Unit becomes active again without relying on file.

Pass/fail criteria
Pass if failures are deterministic and reconciliation occurs when config is corrected.

Cleanup
Restore env file / revert change.

S06 — Secret path changes and missing secret cases

Setup
Container consumes a secret from a known file path.

Action
Change secret path in config and rebuild/switch; then test “missing secret” by removing file.

Assertions
systemctl --user status shows expected success/failure; Podman container state reflects start failure when secret missing.

Pass/fail criteria
Pass if missing secret fails fast with clear logs and recovery works after restoring secret.

Cleanup
Restore secret and rerun the switch.

S07 — Manual drift: edited unit file and stale symlink

Setup
Pick a unit under test and confirm its FragmentPath.

Action A (edit drift)
Modify the on-disk unit file directly (or create a conflicting drop-in). Rebuild/switch.

Assertions

```bash
systemctl --user show <unit> -p FragmentPath -p DropInPaths
systemctl --user cat <unit> | sed -n '1,80p'
```

Expected: drift is detectable (drop-in present, content differs).

Action B (stale symlink)
Replace unit file symlink with a stale target; rebuild/switch.

Pass/fail criteria
Pass if your process detects and corrects drift (or at minimum alarms); fail if drift silently persists.

Cleanup
Remove drift artifacts, regenerate by rebuild.

S08 — Auto-update interaction (Podman)

Setup
Use a container configured for auto-update in a systemd unit context.

Action
Trigger podman auto-update (timer or manual) and then run a rebuild/switch.

Assertions
Podman auto-update is documented to restart systemd units that run containers after pulling an updated image.
Verify:

```bash
journalctl --user -u podman-auto-update.service --no-pager -b || true
podman images
systemctl --user status <unit>
```

Pass/fail criteria
Pass if auto-update and rebuild do not “fight” into oscillation and the final state matches the target generation.

Cleanup
Disable timer and revert image labels for the test.

S09 — Health-check weirdness: stuck unhealthy/starting

Setup
Enable a healthcheck that can flip unhealthy.

Action
Force unhealthy state (e.g., block dependency) and rebuild/switch.

Assertions
Podman supports healthchecks and (in newer Podman) configurable healthcheck actions like restart; document claims this exists and how it behaves.
Verify:

```bash
podman ps --all --format '{{.Names}}\t{{.Status}}'
podman inspect <container> --format '{{.State.Health.Status}}'
systemctl --user status <unit>
```

Pass/fail criteria
Pass if system converges (container healthy or fails clearly and stays failed). Fail if you get loops or silent unhealthy while systemd claims active.

Cleanup
Restore normal health behavior.

S10 — Rebuild with no material config changes

Setup
Clean baseline state; no changes between two rebuilds.

Action
Run rebuild/switch twice.

Assertions
Expect no unnecessary restarts beyond what your tooling defines as needed. For Home Manager, the “switch method / triggers” system exists specifically to avoid unnecessary restarts, and restarts may occur based on diffs/triggers.
Measure:

```bash
systemctl --user show <unit> -p ActiveEnterTimestamp -p ExecMainStartTimestamp
```

Pass if timestamps don’t change (or change only when expected by your policy).

Cleanup
None.

S11 — Rebuild while user manager absent/degraded/not lingering

Setup
Ensure the user manager is not running or is degraded.

Action
Run rebuild/switch.

Assertions
Home Manager explicitly skips reload if user systemd is not running.
For NixOS activation, rebuild output often includes “reloading user units for …”; the activation script reloads user units for users returned by loginctl list-users and starts nixos-activation.service under that user.
Validate:

```bash
systemctl --user is-system-running   # from inside an actual user session if possible
journalctl -u home-manager-<user>.service --no-pager -b || true
```

Pass/fail criteria
Pass if behavior is predictable and you can define a recovery path (next login, linger enablement, or explicit restart). Fail if rebuild claims success but services silently remain stale.

Cleanup
Restore normal user manager conditions.

S12 — Rollback reconciliation (nixos-rebuild switch --rollback)

Setup
Make a change that modifies unit or container behavior (tag change, env var).

Action
Rollback.

Assertions

```bash
podman ps --all --format '{{.Names}}\t{{.Image}}'
systemctl --user show <unit> -p FragmentPath -p ActiveState
```

Pass if rollback converges to previous intended generation behavior (container image, env, secrets), not just the unit file contents.

Cleanup
Return to baseline generation.

## Scenario matrix

| ID | Area | What it stresses | Primary risk it detects | Key assertion(s) |
|---|---|---|---|---|
| S01 | Unit shadowing | ~/.config vs /etc precedence | Wrong unit source chosen | FragmentPath points to highest-precedence copy |
| S02 | Reload semantics | daemon-reload under shadowing | False belief that reload “switches source” | daemon-reload doesn’t change source without removing override |
| S03 | Compose mutation | Image tag update | Stale container image | Container image matches desired tag |
| S04 | Compose mutation | Service rename | Orphaned/stale containers | Old container removed; new created |
| S05 | Env robustness | Missing/removed/malformed env | Non-deterministic failures | Clear failure + deterministic recovery |
| S06 | Secret robustness | Secret path drift | Silent wrong config | Fail-fast on missing secret |
| S07 | Drift | Manual edits / stale links | Declarative state bypassed | Drift detectable via cat / drop-ins |
| S08 | Auto-update | podman auto-update interaction | Restart races / oscillation | Final state matches target generation |
| S09 | Healthcheck | unhealthy/starting edge cases | systemd says active while unhealthy | Converges (healthy) or fails clearly |
| S10 | No-op rebuild | idempotency | Unnecessary restarts | Timestamps stable unless policy triggers |
| S11 | User manager absent | non-linger / degraded | “Switch succeeded but nothing reconciled” | HM skip behavior; NixOS reload scope observable |
| S12 | Rollback | reverse reconciliation | Rollback doesn’t restore runtime | Container + unit converge to prior state |

## Recommendation and risks

### Final architecture recommendation for phase 3

Recommendation: Adopt single-owner user-unit management for the Podman stack units, and if you choose Home Manager as the owner, treat it as an operational system that must be validated under user-manager availability constraints.

Concretely:

- If the dominant pain is the class you observed (stale ~/.config shadowing /etc), then moving ownership into Home Manager is an effective structural mitigation, because it places the authoritative unit in the highest-precedence user path and updates it during activation.
- If your dominant pain is “rebuild-time reconciliation must always happen even if no user manager is running,” then neither approach fully guarantees that while staying in user scope, because Home Manager explicitly skips reload when user systemd isn’t running. In that case you need an operational safeguard design (below) or reconsider scope (system services).

### Decision table

| Dimension | NixOS-managed user unit (/etc/systemd/user) | Home Manager-managed user unit (~/.config/systemd/user) | Hybrid ownership |
|---|---|---|---|
| Unit placement (primary) | Generated into /etc/systemd/user via environment.etc."systemd/user" | Generated into XDG config systemd/user/... (typically ~/.config/systemd/user) | Hard to make safe; risks name collisions |
| Susceptibility to ~/.config shadowing | High (by definition): ~/.config/systemd/user overrides /etc/systemd/user | Lower for this specific class (authoritative copy is already highest-precedence) | Highest risk: two competing sources for same unit name |
| Rebuild-time service reconciliation | NixOS activation reloads user units for users found via loginctl list-users and starts nixos-activation.service ; does not inherently imply full lifecycle management of arbitrary user units | Home Manager runs sd-switch-based switching when user systemd is reachable; otherwise skips | Frequently undefined (double-reload / inconsistent restart logic) |
| Drift resistance | Strong for /etc content but weak if user creates ~/.config overrides | Strong for declared content but still vulnerable to manual drop-ins/edits in ~/.config | Weakest |
| Operational clarity (“where is truth?”) | Split truth: /etc is intended, but ~/.config can override silently | Clearer: “truth is in ~/.config”, but must manage user-manager availability | Lowest clarity |
| Best fit for your objective | Acceptable only if you also prevent/clean shadowing | Best direct match, with explicit residual risks | Not recommended |

### Operational safeguards regardless of approach

These are not “code fixes”; they are operational guardrails derived from the documented behaviors:

- Shadowing detection as a first-class health signal
Always check FragmentPath and DropInPaths for every stack unit and fail the “switch” pipeline (or at least alert) if the path is not the expected owner path. This is the direct way to detect “stale unit shadowing” rather than discovering it via runtime behavior.

- Treat “user manager unavailable” as a failed reconciliation state
Home Manager will skip reload when user systemd isn’t running. Make it observable (logs/alerts) so “no reconcile happened” is not silent success.

- Explicitly test interactions with Podman auto-update
Podman auto-update is designed to restart systemd units that run containers after image updates. If you also restart/reconcile on rebuild, you must test for restart races and ensure the final state is deterministic (S08).

- Make rollback a first-class supported operation
If rollback does not converge runtime state (containers/config/env), you do not have a safe declarative ops story. Run S12 regularly.

### Minimal migration safety checklist

- Inventory current unit names and current loaded sources
Record systemctl --user show <unit> -p FragmentPath -p DropInPaths for every stack unit.

- Enforce single ownership of each unit name
Before migration: ensure that for each unit name, only one authoritative source exists (either /etc/systemd/user or ~/.config/systemd/user). The systemd loader explicitly treats earlier path entries as overriding.

- Plan for the transitional “stale units remain” phase
Migration must include a step that proves old unit files are not still present in higher-precedence directories.

- Validate reconciliation under degraded and absent user manager states
Home Manager will skip reload when the user daemon is not running. This must be an explicit go/no-go gate for “production-safe.”

- Validate Podman-specific edge cases (auto-update, healthcheck)
Podman auto-update expects containers to run inside systemd units and restarts those units. Ensure this doesn’t conflict with rebuild-driven restarts.

## Source list with links

systemd behavior (unit paths, reload/restart/revert semantics)

- systemd.unit(5) — User Unit Search Path and explicit override rule (“directories listed earlier override … lower in the list”).
- systemctl(1) — daemon-reload definition (reruns generators, reloads unit files, recreates dependency tree).
- systemctl(1) — restart semantics and limitations (not necessarily flushes all resources; stop+start may be needed).
- systemctl(1) — reload vs daemon-reload distinction (reload does not reload unit file).
- systemctl(1) — revert definition and vendor-version limitation (vendor is below /usr/; no vendor version implies not removed).

NixOS user unit generation and activation behavior

- NixOS module generating per-user units into /etc/systemd/user via environment.etc."systemd/user".
- NixOS activation-script module defining system.userActivationScripts and the nixos-activation user service.
- NixOS switch-to-configuration.pl (example commit) showing “reloading user units for $name…” and use of systemctl --user daemon-reexec and starting nixos-activation.service for users returned by loginctl list-users.

Home Manager user service generation and activation

- Home Manager modules/systemd.nix — generation of systemd/user/... xdg config files, definition of systemd.user.startServices, and reload logic (checks is-system-running, uses sd-switch, skips if not running).
- Home Manager project README — states NixOS module mode builds profiles with nixos-rebuild.
- Home Manager NixOS module (nixos/default.nix) — system home-manager-<user> oneshot service, runs as user, imports environment from user systemd environment, defaults XDG_RUNTIME_DIR.

Podman interactions that affect systemd lifecycle/reconciliation

- podman-auto-update(1) — auto-update restarts the systemd unit executing the container after pulling an updated image; requires running inside systemd units.
- podman-generate-systemd(1) — notes deprecation and recommends Quadlet for running containers under systemd.
- podman-systemd.unit(5) — systemd unit file options for Podman-managed containers including health-related settings.
- Red Hat blog on Podman healthcheck actions (restart/stop/kill/none; “starting with Podman v4.3”).

---

## nixosconfig-ezp — Reference: Debug Session Notes & Fast Debug Checklist

- **Status:** closed
- **Type:** chore
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Reference documentation for debug sessions and the doc1 fast debug checklist.

## Debug Session Notes

- Record: host, stack, URL, expected status, current status, last change.
- Verify upstream directly with `--resolve` before changing nginx/Cloudflare.
- For Uptime Kuma issues: check `/metrics` and confirm `monitor_status` before assuming DNS or proxy issues.

### Fast Debug Checklist (Doc1)

- `systemctl --user list-units 'podman-compose@*' --no-legend`
- `podman ps --format 'table {{.Names}}\t{{.Status}}'`
- `curl -k --resolve <host>:443:<ip> https://<host>/<health>`
- `key=$(rg -m1 '^KUMA_API_KEY=' ${KUMA_API_KEY_FILE:-/run/secrets/uptime-kuma/api} | cut -d= -f2-); curl -fsS --user ":$key" https://status.ablz.au/metrics | rg 'monitor_status' | rg '<domain>'`

---

## nixosconfig-h9t — Research: Podman autoupdate + compose raw image metadata

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Podman Auto-Update Failures With Compose-Managed Containers on NixOS
Executive summary and conclusion

Your observed failure (locally auto-updating container "<id>": raw-image name is empty) is best explained as a Podman implementation gap/bug in the Docker-compatible (“compat”) container create API path, which is the path used by podman compose when it delegates to docker-compose / docker compose as provider.

In Podman 5.7.1, podman auto-update hard-requires that ctr.RawImageName() be non-empty; if it is empty, Podman records an error and skips the container. However, the compat API CreateContainer handler in 5.7.1 does not set SpecGenerator.RawImageName, which is the record needed for ctr.RawImageName() later. As a result, containers created through this API path can have a valid ImageName/Config.Image but still have empty RawImageName, which reliably breaks podman auto-update.

This is also explicitly reported upstream as a bug for docker-compose/API-created containers (issue #19688).

Conclusion: this is not intended “working as designed” behavior for the compose-managed lifecycle + Podman auto-update combination; it is a known incompatibility stemming from an incomplete implementation in the Docker-compat API create path, and it is still present in the v5.7.1 source shown below.

Confidence: High for root cause (directly supported by 5.7.1 source + upstream bug report).
Confidence: Medium for “fixed in later versions” status (I did not find evidence of a fix in available release notes, and the relevant 5.7.1 code path still exists).
What exactly fails and why it fails
Auto-update requires RawImageName and errors if it is empty

In Podman 5.7.1, auto-update builds a task list over running containers with io.containers.autoupdate set. It reads rawImageName := ctr.RawImageName() and immediately errors out if it is empty, producing the exact message you see.

This is not an incidental log string—RawImageName is used as the image reference for (a) checking digests and (b) pulling updates; the task logic stores it as task.rawImageName and uses it to parse registry references and to pull.

Podman’s own spec generator data model documents the intent: RawImageName is the user-specified, unprocessed image input, and while “optional”, it is “strongly encouraged” when Image is set—specifically because workflows like auto-update need the exact original reference.
Why compose-managed containers tend to have empty RawImageName

podman compose is not a native compose engine; it is a thin wrapper that executes an external provider (typically docker-compose / docker compose), wiring it to the local Podman socket. By default, if docker-compose is installed, it takes precedence.

When the provider is Docker Compose, container creation goes through Podman’s Docker-compat (“compat”) API.

In Podman 5.7.1, the compat CreateContainer handler:

    normalizes the image name (NormalizeToDockerHub),
    looks up the image,
    then creates a SpecGenerator using either the image ID or a resolved name, but never sets SpecGenerator.RawImageName.

Because SpecGenerator.NewSpecGenerator() sets only ContainerStorageConfig.Image (not RawImageName), RawImageName remains unset unless a higher layer explicitly populates it.

So you get the exact mismatch you reported:

    podman inspect shows an image name in several places (e.g., normalized image name),
    but RawImageName (the “original user input”) can still be empty,
    and podman auto-update fails.

This is confirmed by the upstream bug report for docker-compose/API-created containers: “Looks like rawImageName is only set in CLI and play but not in API handler.”
Bug vs design vs edge-case and version behavior
Classification

Bug / implementation gap (most accurate):

    Auto-update requires RawImageName and fails without it (documented by 5.7.1 code).
    The Podman compat API CreateContainer handler does not set RawImageName in 5.7.1 (documented by 5.7.1 code).
    The SpecGenerator model strongly encourages setting RawImageName when Image is set (documented in the model comment).
    Upstream issue #19688 identifies the exact mismatch and is labeled as a bug.

Not “intended behavior”: the spec generator explicitly frames RawImageName as important for exact user input, and the issue report expects parity with CLI-created containers.

Edge-case limitation (secondary framing): Podman also enforces fully-qualified references for registry-based update, because if containers are created from IDs, Podman cannot know which registry reference to check/pull. This is explicitly documented in Podman’s systemd/quadlet unit docs.
However, your case is not “image ID used intentionally”; it is a missing metadata field despite having a usable image name elsewhere.
Does podman compose fail to populate RawImageName “by design”?

If podman compose is using Docker Compose (docker-compose) as provider (the default behavior when installed), it is essentially routing creation through the compat API handler, which in 5.7.1 visibly does not populate RawImageName.

That makes the observed behavior an implementation gap/bug in Podman’s compat API path, not a deliberate “compose must not support auto-update” design choice.
Versions affected and fixed

Directly evidenced as affected

    Podman 5.7.1: compat CreateContainer handler does not set RawImageName; auto-update errors on empty RawImageName.
    Podman 4.6.0 is implicated by the upstream issue reproduction environment, and the reported symptom matches the same missing-field root cause.

Related precedent: fixed elsewhere

    A similar class of bug existed for podman play kube: containers created by podman play kube “did not record the raw image name used to create containers,” and this was later fixed (documented in release notes).
    This supports the interpretation that “missing RawImageName breaks auto-update” is a recognized correctness issue, not an accepted limitation.

Fixed for compat compose path?

    I did not find evidence (in the investigated sources) that compat container create now sets RawImageName in a way that would resolve this in 5.7.1. The 5.7.1 code shown still omits it.
    Issue #19688 is closed/locked, but the closure state alone does not demonstrate a fix; the report contains no linked PR in the captured view.

Confidence: Medium that “no fix exists up through 5.7.1 and the current documented behavior you’re seeing”; High that 5.7.1 is affected.
Officially supported update strategies for compose-managed workloads today
What Podman officially supports well: systemd/Quadlet + auto-update

Podman’s systemd integration (via generator / quadlet-style unit definitions) is where Podman auto-update is most “first-class”:

    Podman’s systemd unit documentation includes AutoUpdate= and explicitly ties it to podman-auto-update(1).
    It also documents the fully-qualified image reference requirement for registry auto-update.

Additionally, Podman’s podman-auto-update documentation explicitly references configuring auto-update via quadlet.

For a homelab/single-host environment, the “Podman-native” strategy that aligns with official documentation is therefore:

    Manage containers via Quadlet/systemd units (user units for rootless)
    Set AutoUpdate=registry (or equivalent labels)
    Run podman-auto-update.timer or invoke podman auto-update on a schedule

What Podman officially provides for compose: a wrapper, not lifecycle semantics

Podman documents that podman compose is a wrapper executing an external compose provider and passing through commands/options.

Therefore, “compose-managed updates” are, in practice, the provider’s update workflow—typically:

    podman compose pull
    podman compose up -d (and sometimes --force-recreate, depending on provider semantics)

This is not a Podman-specific claim of guarantee; it follows directly from “podman compose executes another tool and passes the command/args directly.”
Practical implication for your environment

Because the compat create handler in 5.7.1 does not set RawImageName, Podman-native auto-update is not operationally reliable for containers created via docker-compose over the Podman socket.

So, “officially recommended” in the sense of “most supported by Podman docs and implementation” is:

    Use Quadlet/systemd-managed containers for auto-update, or
    Use compose pull + redeploy as your update mechanism when you stay on compose.

Best practices for rootless + systemd + compose in ops
Scheduling and observability with systemd timers

Systemd timers are explicitly designed for time-based activation of services (cron-like scheduling under systemd supervision). For a homelab goal of low-toil + reliable logging, this matters because timer-triggered services:

    run under a consistent unit name,
    emit logs to journald in a centralized way (systemd-managed).

Prefer Podman’s systemd/Quadlet integration for “production-like” stability

Podman’s systemd unit docs emphasize that it supports both system and user units, and that unit generation is integrated into boot/daemon-reload.

Enterprise guidance (RHEL documentation) explicitly positions Quadlet as having “many advantages” over generated unit files and notes Quadlet availability in recent Podman versions (starting with Podman v4.6 in that doc). This is a strong signal that “systemd-native container units” are the long-term-friendly management approach.
Compose in production/homelab: minimize “API impedance mismatch”

Given podman compose defaults to Docker Compose if installed, and Docker Compose uses the compat API path, you should assume “Docker API semantics” apply unless proven otherwise.

When an operational feature depends on Podman-internal metadata (like RawImageName), prefer workflows that create containers through Podman-native code paths (Quadlet/CLI) over Docker-compat code paths. This is an inference supported by the specifically missing RawImageName in the compat handler vs its use in auto-update.
Watchtower in Podman environments
Compatibility and maintenance status

Watchtower’s documented operating model is to run as a container which must mount the Docker socket because it “needs to interact with the Docker API.”

There are long-running upstream Watchtower discussions requesting Podman support because Watchtower expects /var/run/docker.sock and Docker API behavior.

More importantly for 2026 operational decision-making: the upstream Watchtower repository was archived (read-only) on December 17, 2025, which indicates the original project is no longer actively maintained in its upstream home.
Risk profile compared to Podman-native approaches

Based on Watchtower’s requirement to mount a privileged control socket for the container runtime (Docker API socket), Watchtower inherently expands the blast radius of a compromise of the Watchtower container (general socket-mount risk). This is a security inference from the documented requirement to mount the control socket.

Podman’s preferred path for automatic updates is integrated with systemd/quadlet (AutoUpdate=) and podman auto-update, which avoids introducing an additional third-party controller container.
Bottom line

For Podman environments in 2026, Watchtower is generally redundant at best and risky at worst, and the archival of the upstream repo materially increases operational risk.

Confidence: High that Watchtower relies on Docker API socket mounting; High that upstream repo is archived; Medium that it is “not recommended” for Podman specifically (because some people run it against Podman’s Docker-compat socket, but you inherit both compatibility gaps and a now-archived upstream).
Remediation options, decision matrix, and a rollout plan
Can missing raw image metadata be repaired in place?

Practically, treat this as not repairable in place.

Podman’s internal container config states the container configuration “may not be changed once created” and is stored read-only in state; changes are not written back and can cause inconsistencies.

Since podman auto-update uses ctr.RawImageName() and fails when empty, the remediation is to ensure new containers are created with RawImageName populated, rather than trying to mutate existing containers.

Confidence: Medium-high (based on Podman internal documentation + behavior), but note this is based on upstream code comments rather than a “supported admin API” statement.
What “creation paths” will populate RawImageName?

From the upstream bug report perspective, RawImageName is “set in CLI and play but not in API handler.” In your case, this implies:

    Docker-compat API path (docker-compose / docker compose provider): does not set it in 5.7.1.
    Podman-native creation paths: are expected to set it (at least in the cases called out by upstream), and Podman historically fixed missing-raw-image-name issues in other command paths (e.g., play kube).

Decision matrix
Option	Reliability in real ops	Operational complexity	Downtime risk	Security posture	Notes / key tradeoffs
Stay on podman auto-update + wait for fix	Low (for docker-compose/compat-created containers) 	Low (no changes)	Low (but you’re not updating)	Good (Podman-native)	You will keep getting “raw-image name is empty” until containers are created with RawImageName populated or Podman changes compat handler.
Recreate containers under a path that sets required metadata	Medium–High (if you truly move off compat create) 	Medium	Medium (recreate events)	Good	Requires changing how containers are created (e.g., Quadlet or Podman-native create path). Container config is not meant to be mutated in place.
Replace with pull/redeploy script per stack (podman compose pull && up -d)	High (most predictable) 	Medium (per-stack timers/scripts)	Medium (depends on restart strategy)	Good	Uses compose provider semantics; avoids RawImageName entirely. Works even when compat path can’t support auto-update.
Use Watchtower	Low–Medium (depends on compat/socket behavior) 	Medium	Medium	Worse (socket-mount controller) 	Upstream is archived/read-only as of Dec 17, 2025, increasing long-term risk.
Recommended operational path for a homelab

Given your stated priorities (“low toil, high reliability”) and the demonstrated incompatibility between auto-update and compat-created containers, the most pragmatic approach is:

    Short term: move to per-stack pull + redeploy under systemd timers (option 3).
    Medium term: migrate “important” stacks to Quadlet/systemd units with AutoUpdate=registry (Podman-native path), so you can use Podman’s supported auto-update model without compose/provider edge cases.
    Avoid: Watchtower, unless you accept the security tradeoff and the archived-upstream risk.

Confidence: High for “option 3 works around the RawImageName failure”; Medium-high for “Quadlet migration is the best-aligned long-term strategy.”
Practical rollout plan with rollback
Preparation phase

Create an inventory report that lets you separate:

    containers that can be auto-updated today vs those that cannot, and
    which stacks are impacted.

Example checks (illustrative commands):

    Identify containers with the autoupdate label
    Ensure RawImageName is populated (this is the key failure point)
    Confirm PODMAN_SYSTEMD_UNIT label is set where you expect

This is justified because 5.7.1 auto-update will otherwise fail at task-assembly time.
Phase one: stabilize updates via compose redeploy

For each stack:

    Create a systemd .service that runs the external compose provider command you already rely on (podman compose ...). This leverages the fact that podman compose simply passes through to the provider you have installed.
    Create a matching .timer with an OnCalendar= schedule. Systemd timers are explicitly intended for time-based activation.
    Implement an update routine:
        podman compose pull
        podman compose up -d
        (Optionally include provider-specific flags to reduce downtime or force recreation, depending on your provider’s behavior—this is provider-defined since podman compose delegates.)

Rollback strategy:

    If the update breaks functionality, revert the compose file to the prior image tag/digest and run podman compose up -d again.
    Because this is compose-driven, rollback is tied to your compose configuration and image tagging policy, not to Podman auto-update state. (This is an operational inference based on compose delegation.)

Phase two: migrate high-value stacks to Quadlet auto-update

For the stacks where you most want Podman-native auto-update:

    Convert the stack from compose to Quadlet/systemd units (container or pod units as appropriate). Podman documents this systemd integration and AutoUpdate= in podman-systemd.unit(5).
    Use fully-qualified image references when using AutoUpdate=registry, per the Podman systemd unit documentation.
    Enable Podman’s update timer or schedule podman auto-update using a systemd timer (the latter is consistent with systemd’s model).

Rollback strategy:

    Keep a known-good image tag available and ensure your systemd unit can be reverted to it; Podman auto-update also has explicit rollback logic in its implementation when Rollback is enabled (as seen in code).

Decommission phase

Once you have either:

    moved the stack to Quadlet, or
    accepted compose redeploy as your update mechanism,

you should remove io.containers.autoupdate=registry from containers that are still created via the compat compose path, because it will produce persistent update errors and noise. This follows from the documented failure mode in 5.7.1.

---

## nixosconfig-1fd — Phase 2: Verification checklist

- **Status:** open
- **Type:** task
- **Priority:** 1
- **Created:** 2026-02-24

### Description

Post-deployment verification for Phase 2 split services:

Boot/Startup:
- [ ] Linger ensures user session exists before system services run
- [ ] System secrets service waits for user@.service
- [ ] User service starts after podman.socket
- [ ] All env files decrypted to /run/user/<uid>/secrets/
- [ ] All containers start successfully

nixos-rebuild switch:
- [ ] Changing compose file triggers system service restart
- [ ] Changing SOPS file triggers system service restart
- [ ] System service bounces user service correctly
- [ ] Only changed stack restarts (per-stack granularity)
- [ ] Stale health detection runs before reuse
- [ ] No journal spam from orphaned timers
- [ ] Stack operations ~2-3s faster (removed redundant pruning)

podman auto-update:
- [ ] Auto-update finds containers (io.containers.autoupdate=registry)
- [ ] Auto-update restarts correct unit (PODMAN_SYSTEMD_UNIT=.service)
- [ ] User service restart succeeds (env files exist)
- [ ] Stale health detection runs in user service
- [ ] Health checks pass / rollback works
- [ ] Gotify notifications work

Manual operations:
- [ ] systemctl --user restart .service works
- [ ] systemctl restart -secrets.service works
- [ ] systemctl status shows correct states
- [ ] journalctl -u shows logs for both services
- [ ] podman ps shows containers owned by correct project

Service naming:
- [ ] Old services removed (-stack.service, podman-compose@*.service)
- [ ] New services present (-secrets.service, .service)
- [ ] Monitoring updated for new names
- [ ] No orphaned systemd units

Cleanup:
- [ ] No redundant container pruning (verify with strace/journal)
- [ ] No pod pruning (obsolete with docker-compose backend)
- [ ] Timer cleanup still works (orphaned health check timers)
- [ ] systemctl --user reset-failed works

Test on first deployment (single stack), then verify on full rollout.

### Notes

Phase 2 implementation complete (commit d395da2). Ready for deployment testing.

**Deployment Procedure:**

1. Deploy to proxmox-vm:
   ```bash
   nixos-rebuild switch --flake github:abl030/nixosconfig#proxmox-vm --target-host proxmox-vm
   ```

2. Verify service creation:
   - System secrets services exist: `systemctl list-units | grep -- "-secrets"`
   - User compose services exist: `systemctl --user list-units | grep -- "-stack"`
   - Old services removed: No `{stackName}-stack` or `podman-compose@*` services

3. Verify one stack (e.g., immich):
   ```bash
   # Check secrets service
   systemctl status immich-stack-secrets

   # Check user service
   systemctl --user status immich-stack

   # Verify containers running
   podman ps | grep immich

   # Check logs for issues
   journalctl -u immich-stack-secrets -n 50
   journalctl --user -u immich-stack -n 50
   ```

4. Test trigger paths:
   - nixos-rebuild: Change one stack's SOPS file, rebuild, verify restart
   - Auto-update: Manually trigger `podman auto-update`, verify correct service restart

5. Deploy to igpu (5 stacks):
   ```bash
   nixos-rebuild switch --flake github:abl030/nixosconfig#igpu --target-host igpu
   ```

6. Monitor health:
   - Check Uptime Kuma for service availability
   - Check Loki logs for errors: `{host="proxmox-vm"} |= "error"`
   - Verify no orphaned health check timer spam

**Success Criteria:**
- All containers start successfully
- No service activation failures
- Cleanup operations ~2-3s faster (verify via journal timestamps)
- Auto-update restarts correct unit (user service)
- No orphaned timers or stuck health checks

---

## nixosconfig-4jg — Package loki-mcp for PyPI + MCP Registry

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Same pattern as pfsense-mcp: add loki_mcp/ package dir, __init__.py, __main__.py, copy generated/server.py, update pyproject.toml with full metadata + console_scripts, create server.json (io.github.abl030/loki-mcp), add mcp-name comment to README, build + publish.

---

## nixosconfig-6l1 — Phase 3: Simplify auto-update wrapper (podman)

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Clean up auto-update wrapper now that auto-update works natively with user services.

## Changes

1. **Rewrite auto-update script:**
   - Use podman auto-update --format "{{.Unit}} {{.Image}} {{.Updated}}"
   - Parse for failed or rolled_back entries
   - Send Gotify on failure with specifics
   - Exit 0 on success, 1 on failure

2. **Remove workarounds:**
   - 30s sleep
   - Dry-run detection
   - Double-execution logic

3. **Improve timer:**
   - Add RandomizedDelaySec=900
   - Add AccuracySec=1us

## Files

- modules/nixos/homelab/containers/default.nix (auto-update script)

## Reference

docs/podman-compose-failures.md Part 5, Phase 3

---

## nixosconfig-ocm — pfSense reliability & observability

- **Status:** open
- **Type:** epic
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Tracking all pfSense hardening, monitoring, and reliability improvements. pfSense is the network's single point of failure — DNS, firewall, routing all depend on it. This epic covers: syslog reliability, DNS cache warming, service watchdogs, and future observability improvements.

---

## nixosconfig-c87 — Submit MCPs to awesome-mcp-servers lists

- **Status:** open
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Submit PRs to community directories for visibility: (1) punkpeye/awesome-mcp-servers — PR to README.md under Cloud Platforms/Developer Tools (2) appcypher/awesome-mcp-servers (3) mcpservers.org submit form. Lead with the AI-driven testing methodology and 99% first-attempt success rate.

---

## nixosconfig-0qs — Investigate secret leakage risk in episodic-memory archives

- **Status:** closed
- **Type:** task
- **Priority:** 1
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Episodic memory archives full conversation transcripts including MCP tool outputs. If UniFi/pfSense MCP returns WiFi passwords, firewall rules with IPs, or other secrets, they get stored in the SQLite DB. Investigate: (1) Does episodic-memory have any redaction/filtering capability? (2) Is ~/.claude/episodic-memory/ properly excluded from git? (3) Could search results surface secrets that then get written to tracked files (beads notes, MEMORY.md)? (4) Consider adding a pre-archive filter or configuring sensitive MCP tools to not archive outputs.

### Notes

Syncthing now syncs conversation-archive which contains full conversation JSONL + summaries. These may contain secrets mentioned in chat. Consider .stignore patterns or scrubbing.

---

## nixosconfig-ab0 — Add episodic-memory MCP server to fleet

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Wire episodic-memory as MCP server in .mcp.json. Exposes episodic_memory_search (vector/text/hybrid) and episodic_memory_show (conversation reader). Add SessionStart hook for conversation sync.

---

## nixosconfig-rqo — Phase 2: Split services by privilege (podman)

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Separate SOPS decryption from compose lifecycle for proper privilege separation.

## Architectural Decisions (2026-02-12)

1. **Multi-file secrets**: Preserve separation - decrypt each envFile to separate path in /run/user/<uid>/secrets/. Pass multiple --env-file args to compose. No merging.

2. **SOPS sharing**: Verified no stacks share SOPS files (24 use unique encEnv, 1 uses encAcmeEnv). No thundering herd risk.

3. **Cleanup script**: SIMPLIFY to only handle orphaned health check timers. Remove redundant container prune (global timer handles it) and obsolete pod prune (docker-compose doesn't create pods). See Appendix F.

4. **Restart triggers**: System service always reruns decrypt + bounce (simpler than conditional logic).

## Changes Required

1. **Rewrite mkService to generate TWO services per stack:**

   System service (${stackName}-secrets.service):
   - Type=oneshot; RemainAfterExit=true
   - Runs as root for SOPS decryption using /var/lib/sops-nix/key.txt
   - ExecStart: Decrypt ALL envFiles to separate paths (preserve multi-file structure)
   - ExecStartPost: chmod/chown all files, then bounce user service via runuser
   - Depends on user@<uid>.service (After + Requires)
   - restartTriggers: ALL SOPS files + compose file (trigger proxy)
   
   User service (${stackName}.service):
   - Type=oneshot; RemainAfterExit=true  
   - ExecStartPre: Verify ALL env files exist (retry loop 30s each)
   - ExecStart: podman compose with multiple --env-file args (no merging)
   - After/Wants: podman.socket
   - Environment: PODMAN_SYSTEMD_UNIT=${stackName}.service
   - ExecStartPost/StopPost: stackCleanupSimplified (timer cleanup only)
   - restartIfChanged=false (system service bounces it)

2. **Simplify stackCleanup script:**
   REMOVE: sleep 2, container prune (redundant), pod prune (obsolete)
   KEEP: orphaned health check timer cleanup, systemctl reset-failed
   BENEFIT: ~2-3s faster per operation, 38 redundant scans/day eliminated

3. **Service bounce pattern (researched):**
   +/run/current-system/sw/bin/runuser -u ${user} -- sh -c 'export XDG_RUNTIME_DIR=/run/user/<uid>; systemctl --user restart ${stackName}.service'

4. **Testing:**
   - Stacks come up on boot (linger → user session → services)
   - podman auto-update restarts user service correctly
   - Per-stack granularity (changing one stack only restarts that one)
   - Multi-file env files all decrypted and passed to compose
   - No journal spam from orphaned timers
   - Operations ~2-3s faster (removed redundant pruning)

## Files

- stacks/lib/podman-compose.nix
- modules/nixos/homelab/containers/default.nix

## Reference

docs/podman-compose-failures.md Part 5, Phase 2
Appendix C (cross-scope service management)
Appendix D (socket scope)
Appendix F (cleanup script necessity)

### Notes

## Additional Architectural Decision (2026-02-12)

5. **Stale health detection placement**: Run in BOTH services for complete coverage:
   - System service ExecStartPre: handles nixos-rebuild path (runs before bounce)
   - User service ExecStartPre: handles auto-update path (runs when auto-update restarts user service directly)
   - Rationale: Auto-update bypasses system service, so detection must be in user service too. Slight redundancy on nixos-rebuild acceptable for defensive coverage.

## Service Naming
- System: ${stackName}-secrets.service (e.g., immich-secrets.service)
- User: ${stackName}.service (e.g., immich.service)
- PODMAN_SYSTEMD_UNIT=${stackName}.service (points to user service)

---

## nixosconfig-dmb — pin ha-mcp fastmcp<3 — revert when upstream fixes #645

- **Status:** closed
- **Type:** bug
- **Priority:** 3
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

ha-mcp 6.7.0 crashes silently with fastmcp 3.0.0 (show_cli_banner renamed to show_server_banner, _tool_manager removed). Pinned fastmcp<3 in scripts/mcp-homeassistant.sh. Upstream issues: #644, #645, #648. Revert the pin once ha-mcp releases a version that supports fastmcp>=3.

### Notes

## MCP Resilience Analysis

**Nix-managed (pinned, safe):** loki, pfsense, unifi, lidarr, slskd, vinsight — installed via Home Manager, deps locked by nix.

**uvx runtime-resolved (vulnerable to upstream breakage):** ha-mcp (pinned fastmcp<3 as workaround), mcp-nixos, prometheus-mcp-server, beads-mcp.

**Failure mode:** uvx resolves latest compatible version at install/cache-refresh time. If an upstream dep ships a breaking change without proper version bounds (like fastmcp 3.0 did), the MCP server crashes silently — Claude Code just shows 'no tools found' with no hint why.

**Mitigation:** Pin deps in wrapper scripts when breakage occurs. Don't over-engineer — version pins are sufficient for third-party MCPs.

---

## nixosconfig-5p1 — Decision: Container lifecycle strategy (no deploy-time --wait)

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

# Decision: Container Lifecycle Strategy for Rebuild vs Auto-Update

**Date:** 2026-02-12
**Status:** Implemented and evolved (Phase 1 + Phase 2 complete; ownership follow-up moved to Phase 2.5)
**Related Beads:** nixosconfig-cm5 (research), nixosconfig-hbz (bug fix)
**Research Document:** [container-lifecycle-analysis-2026-02.md](../research/container-lifecycle-analysis-2026-02.md)
**Empirical Test:** [2026-02-13-compose-change-propagation-test.md](../incidents/2026-02-13-compose-change-propagation-test.md)
**Ownership follow-up decision:** [2026-02-13-home-manager-user-unit-ownership.md](2026-02-13-home-manager-user-unit-ownership.md)
**Implementation:** [stacks/lib/podman-compose.nix](../../../stacks/lib/podman-compose.nix)

## Planned Follow-up Trial (2026-02)

We will trial a simplified reliability model to reduce control-plane coupling:
- Keep container `healthcheck` definitions in compose.
- Stop using `compose --wait` as a host activation gate.
- Continue enforcing `io.containers.autoupdate=registry` + `PODMAN_SYSTEMD_UNIT` as a hard invariant.
- Prefer failure surfacing via user service state and monitoring alerts over blocking `nixos-rebuild switch`.

Intent:
- Improve deploy robustness by decoupling host config activation from slow/stuck runtime health transitions.
- Reduce reliance on preflight remediation scripts where possible after the trial.

Status:
- Phase 1 implemented: deploy path no longer uses compose `--wait`.
- Phase 2 implemented: user service is sole lifecycle owner with native `sops.secrets` wiring.
- Existing hardening/invariant behavior documented below remains current.

## Update (2026-02-13)

Additional hardening was applied after the initial rollout:

- Startup timeout is globally bounded at 5 minutes (`startupTimeoutSeconds ? 300`) for both the system secrets unit and user compose unit.
- Compose deploy path now runs without `--wait`; timeout bounds still apply to service activation/retry behavior.
- Stale health and label mismatch checks now query both project label families:
  - `io.podman.compose.project`
  - `com.docker.compose.project`
- `StartedAt` timestamp parsing is normalized before `date -d` to avoid timezone-name parsing failures.
- Label mismatch behavior is hard-fail by design (containers are removed when `PODMAN_SYSTEMD_UNIT` does not match expected ownership).

## Phase 2 Completion Update (2026-02-13)

Phase 2 control-plane simplification is complete and deployed to `igpu` and `doc1`.

What changed:
- Removed orchestration role of `*-stack-secrets.service`.
- Removed root-side bounce path (`runuser ... systemctl --user restart ...`).
- User service `${stackName}.service` is now the sole stack lifecycle owner.
- Env secret delivery now uses native system-scope `sops.secrets` with runtime-readable ownership.
- Added one-release compatibility fallback for legacy env paths with explicit warning logs.
- Missing secrets remain hard-fail for stack startup.
- Deploy path remains non-blocking (`podman compose up -d --remove-orphans`, no `--wait`).

## Empirical Addendum (2026-02-13, `igpu`)

Facts from an explicit compose-change propagation test are captured in:
- [2026-02-13-compose-change-propagation-test.md](../incidents/2026-02-13-compose-change-propagation-test.md)

Observed:
- A compose change produced updated unit/script artifacts in the new NixOS generation.
- The active user manager can continue to run a stale unit from `~/.config/systemd/user` when such an override path exists.
- In that state, service restart behavior follows the stale user-level unit definition rather than the updated `/etc/systemd/user` unit.

Decision update:
- The earlier "dual service architecture is required" conclusion is superseded by the Phase 2 design.
- Current design keeps hard-fail invariant enforcement while reducing orchestration coupling.

## Phase 2.5 Update (2026-02-13)

Phase 2 proved the simplified user-scope lifecycle model, but the `igpu` propagation test exposed an ownership-collision class:

- NixOS-generated stack user units under `/etc/systemd/user` can be shadowed by stale user-level unit files in `~/.config/systemd/user`.
- In that condition, `daemon-reload` and `restart` continue using the higher-precedence stale user-level unit.

Phase 2.5 decision:

1. Keep stack lifecycle in user scope.
2. Migrate stack unit ownership to Home Manager `systemd.user.services` so authoritative unit definitions live in user-level path.
3. Enforce single ownership per unit name and add post-switch `FragmentPath`/`DropInPaths` checks.
4. Treat user-manager availability as an explicit reconciliation gate (do not treat skipped user reload as silent success).

See:
- Decision: `docs/podman/decisions/2026-02-13-home-manager-user-unit-ownership.md`
- Plan: `docs/podman/current/phase2.5-home-manager-migration-plan.md`
- Research: `docs/podman/research/home-manager-user-service-migration-research-2026-02.md`

## Incident Addendum (2026-02-13)

Observed production failure mode in the auto-update window:

- `doc1` (`proxmox-vm`) at ~`00:06` AWST: `52` errors
- `igpu` at ~`00:14` AWST: `13` errors
- Common error: `no PODMAN_SYSTEMD_UNIT label found`

Diagnosis summary:

- Affected containers were labeled `io.containers.autoupdate=registry`.
- Those same containers lacked `PODMAN_SYSTEMD_UNIT`.
- Result: `podman auto-update` had no systemd restart target and failed per-container.

Decision reinforcement:

- Treat label pairing as a strict invariant, enforced in preflight:
  - `io.containers.autoupdate=registry` => `PODMAN_SYSTEMD_UNIT` required.
- Violation is a hard startup failure for the stack.
- Goal: fail fast at deploy/start time, not later during timer-based auto-update.

## Context

During Phase 1 migration from `podman-compose` to `podman compose`, we encountered stale container health check issues that caused deployments to hang indefinitely. This raised questions about whether our dual service architecture was correct and whether we should use different strategies for rebuild vs auto-update scenarios.

## Questions Answered

1. **Does container reuse with `--wait` cause stale health checks?**
   → YES - confirmed via research, documentation, and production experience

2. **Should rebuild and auto-update use different strategies?**
   → They ALREADY DO - dual services are correctly optimized for their use cases

3. **Is the dual service architecture necessary?**
   → YES - each service serves a distinct purpose with appropriate optimizations

4. **Should we use `--force-recreate` to avoid stale containers?**
   → NO - defeats the purpose of incremental rebuilds; use targeted detection instead

## Decision (Historical Snapshot, Later Evolved by Phase 2)

**Keep current dual service architecture with targeted stale health detection.**

### Rationale

**Finding #1: Dual Services Are Correct By Design**

```
System Service (<stack>-stack.service):
  - Triggered by: nixos-rebuild switch
  - Purpose: Apply config changes incrementally
  - Strategy: Smart container reuse (fast, only restart what changed)
  - Optimization: Preserves containers when config unchanged

User Service (<stack>.service):
  - Triggered by: podman auto-update → systemd restart
  - Purpose: Pull new images, deploy updates
  - Strategy: Full recreation (systemd ExecStop → ExecStart lifecycle)
  - Optimization: Fresh containers with new images (Watchtower-style)
```

**Finding #2: User Services Already Recreate Containers**

User services don't need `--force-recreate` because systemd's service lifecycle already provides full recreation:
1. Systemd runs ExecStop (stops containers)
2. Then runs ExecStart (creates fresh containers)
3. Result: Clean slate every auto-update

This discovery eliminated the need to change user service behavior.

**Finding #3: Stale Health is a Targeted Problem**

The issue only occurs during rebuild when:
- Container has stuck health check from previous run
- Config is unchanged (so docker-compose reuses container)
- `--wait` blocks on stale health status
- No new health checks are scheduled

**Finding #4: Targeted Remediation Beats Blanket Workaround**

Using `--force-recreate` on system service would:
- ❌ Restart ALL containers on every rebuild (slow)
- ❌ Cause unnecessary downtime
- ❌ Defeat the purpose of incremental config changes
- ❌ Waste time recreating healthy containers

Targeted stale health detection:
- ✅ Only removes broken containers
- ✅ Preserves fast path for healthy containers
- ✅ Automatic remediation (no manual intervention)
- ✅ Low overhead (quick inspect check)

## Implementation

**Status:** ✅ Completed (initial: e194187; hardened: f922af4, 003e8b1)

### Stale Health Detection

**Location:** `stacks/lib/podman-compose.nix` (`healthCheckTimeout`, `startupTimeoutSeconds`, `detectStaleHealthScript`, `recreateIfLabelMismatchScript`)

```nix
# Add parameter to mkSystemdService function:
healthCheckTimeout ? 90  # Default 90 seconds, configurable per-stack

detectStaleHealth = [
  ''
    /run/current-system/sw/bin/sh -c '
      ids=$(
        {
          ${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format "{{.ID}}"
          ${podmanBin} ps -a --filter label=com.docker.compose.project=${projectName} --format "{{.ID}}"
        } | /run/current-system/sw/bin/awk 'NF' | /run/current-system/sw/bin/sort -u
      )
      for id in $ids; do
        health=$(${podmanBin} inspect -f "{{.State.Health.Status}}" $id 2>/dev/null || echo "none")
        started=$(${podmanBin} inspect -f "{{.State.StartedAt}}" $id 2>/dev/null)

        # Only remove if unhealthy/starting AND running for >threshold
        if [ "$health" = "starting" ] || [ "$health" = "unhealthy" ]; then
          started_clean=$(echo "$started" | /run/current-system/sw/bin/awk '{print $1, $2, $3}')
          age_seconds=$(( $(date +%s) - $(date -d "$started_clean" +%s) ))
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

**Edge Case Protection:**
- **Default 90 seconds:** Covers most services (2-3x typical 30-45s startup time)
- **Rapid rebuilds safe:** Won't get stuck in multi-minute loops during development
- **Configurable per-stack:** Slow services can override (e.g., `healthCheckTimeout = 300` for database migrations)
- **Formula:** Set to 2-3x expected startup time for the slowest container in the stack

Add to `mkExecStartPre` call:
```nix
ExecStartPre = mkExecStartPre envFiles (podPrune ++ detectStaleHealth ++ recreateIfLabelMismatch ++ preStart);
```

### Verification Steps

**Phase 1: Dev Environment Validation**

1. **Create test stack with intentional failure:**
   ```bash
   # On dev VM
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

2. **Wait for stuck state (2+ minutes):**
   ```bash
   watch 'podman ps -a --format "{{.Names}}: {{.Status}}"'
   # test-slow should show "Up X minutes (health: starting)"
   # After 90+ seconds, detection script should remove it
   ```

3. **Run detection script manually:** Verify it identifies stuck container but NOT the healthy one

4. **Test in NixOS stack:** Add test stack to doc1, trigger rebuild, verify auto-remediation

**Phase 2: Production Validation**

1. Deploy to doc1, monitor first rebuild
2. Check journalctl for detection messages
3. Verify no false positives (healthy containers removed)
4. Deploy to igpu during migration (expect same issues, verify auto-remediation)

**Success Criteria:**
- ✅ Containers stuck >90s are removed
- ✅ Containers <90s in "starting" state are NOT removed (unless overridden per-stack)
- ✅ Healthy containers are never touched
- ✅ Clear logging shows what was removed and why
- ✅ Rapid rebuilds don't get stuck in multi-minute loops

## Alternative Approaches Considered

### Option A: --force-recreate on System Service
**Decision:** REJECTED

Would solve stale health issue but:
- Defeats purpose of incremental rebuilds
- Causes unnecessary downtime
- Slower deployments (2-5s per container × 19 stacks)
- Restarts healthy containers for no reason

### Option B: --force-recreate on User Service
**Decision:** NOT NEEDED

User services already recreate via systemd lifecycle (ExecStop → ExecStart). Adding the flag would be redundant.

### Option C: Separate compose files for rebuild vs update
**Decision:** REJECTED

Would add complexity without solving the root cause. Both scenarios need the same container configuration.

### Option D: Remove --wait flag
**Decision:** REJECTED

Would lose critical benefits:
- Can't detect deployment failures
- Auto-update can't detect rollbacks
- Services might depend on broken stacks
- No reliable success/failure indication

## Lessons from Watchtower

Watchtower's always-recreate approach worked reliably for years. However:
- Watchtower only handles auto-update scenario (not rebuild)
- Our user services already implement Watchtower-style recreation
- System services need different optimization (incremental, not full recreation)
- The dual service architecture gives us the best of both worlds

## Success Criteria

1. ✅ Rebuild deployments don't hang on stale health checks
2. ✅ Healthy containers are reused (fast path preserved)
3. ✅ Auto-update continues to work reliably
4. ✅ No manual intervention needed for stuck containers
5. ✅ Clear logging when stale containers are removed

## Test Matrix (Invariant Enforcement)

All tests run on both hosts: `doc1` and `igpu`.

1. **Baseline audit (pre-change snapshot)**
- Record current auto-update label pairing:
  - `podman ps -a --format '{{.ID}}' | xargs -r podman inspect | jq -r '.[] | select(.Config.Labels["io.containers.autoupdate"]=="registry") | "\(.Name) \(.Config.Labels["PODMAN_SYSTEMD_UNIT"] // "MISSING")"'`
- Expected: no `MISSING` lines after rollout.

2. **Negative test (must hard-fail)**
- Create one controlled mismatch in a test stack/container:
  - `io.containers.autoupdate=registry` set
  - `PODMAN_SYSTEMD_UNIT` absent
- Start stack service.
- Expected: service fails in `ExecStartPre` with explicit mismatch output.

3. **Positive test (must pass)**
- Add valid `PODMAN_SYSTEMD_UNIT=<stack>.service` for same test.
- Start stack service again.
- Expected: preflight passes and service reaches active/exited success state.

4. **Auto-update dry run validation**
- Run `podman auto-update --dry-run`.
- Expected: no `no PODMAN_SYSTEMD_UNIT label found` errors.

5. **Timer-path validation**
- Let scheduled `podman-auto-update.service` run once (or trigger manually in equivalent path).
- Expected: no missing-label errors in `journalctl -u podman-auto-update.service`.

6. **Regression guard for compose label families**
- Ensure preflight coverage includes both:
  - `io.podman.compose.project`
  - `com.docker.compose.project`
- Expected: mismatch detection works regardless of which project label family the container has.

## References

- Full research: [container-lifecycle-analysis-2026-02.md](../research/container-lifecycle-analysis-2026-02.md)
- Research bead: `bd show nixosconfig-cm5`
- Bug bead: `bd show nixosconfig-hbz`
- CLAUDE.md: Container Stack Management section

## Next Steps

1. Implement `detectStaleHealth` in `stacks/lib/podman-compose.nix`
2. Test on doc1 with controlled scenario
3. Deploy to production, monitor for issues
4. Apply to igpu during migration
5. Document health check best practices in stack templates (Recommendation 2)
6. Consider health check monitoring (Recommendation 5, low priority)

---

## nixosconfig-6su — Research: Phase 2.5 risk analysis and solutions

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Risk and Solutions Analysis for Home-Managed User systemd Stack Units on NixOS
Executive summary

This migration changes the authority boundary for user-unit definitions from a system-owned unit directory (/etc/systemd/user) to a user-owned unit directory (~/.config/systemd/user). In systemd user mode, the user configuration directory has higher precedence than /etc/systemd/user, so a correctly-present, correctly-loaded ~/.config/systemd/user/<unit>.service will override any legacy definition in /etc/systemd/user. However, “correctly present” and “correctly loaded” are non-trivial once you add (a) oneshot + RemainAfterExit=true semantics, (b) autoupdate-induced restarts, (c) Home Manager’s collision guardrails, and (d) the fact that systemd can apply drop-ins from other paths even when the main fragment comes from ~/.config.

The three unresolved problems you listed map to three distinct reliability gaps:

    Ambiguous restart outcomes (Issue 1) is primarily a semantic mismatch between “systemd unit state” and “container stack health/readiness,” made worse by oneshot semantics where success often means “the CLI returned,” not “the workload is healthy.” systemd explicitly notes oneshot behavior and how RemainAfterExit affects “active” state. Podman auto-update further warns that unit restart can appear successful even if the container fails shortly after, unless readiness is signaled (e.g., SDNOTIFY).
    Drift recovery (Issue 2) is primarily a Home Manager activation collision policy problem: by design, Home Manager checks for “existing file is in the way” collisions during checkLinkTargets and fails fast, and activation scripts cannot easily “delete first” because collision checks precede the write boundary.
    Reconciliation timing (Issue 3) is primarily an activation-triggering and daemon reload problem: systemd may continue running with a previously loaded unit until daemon-reload, and systemd exposes NeedDaemonReload to indicate the unit’s FragmentPath/SourcePath changed since last read. Home Manager also has an explicit option to start/stop/reload/enable services at activation time (including an “apply automatically” mode via sd-switch) but that still depends on activations actually running when you need them.

Preferred approaches, aligned with your constraints (user scope, keep Podman auto-update + PODMAN_SYSTEMD_UNIT, minimize toil, stay declarative):

    Issue 1 (restart ambiguity): keep oneshot if you want, but add a hard post-start verification gate (ExecStartPost=) that fails the unit if expected containers are not running/healthy within a bounded timeout; use explicit exit codes and journald-structured logging so automation can treat systemctl --user restart as authoritative. This leverages systemd’s documented failure behavior for ExecStartPre/ExecStartPost.
    Issue 2 (drift recovery): enable strong auto-heal for just the unit artifacts by setting per-file force = true on the managed unit files (and any managed drop-ins) so activation overwrites local replacements instead of failing; optionally use backupFileExtension only where you truly want backups, since repeated backup collisions are a known sharp edge.
    Issue 3 (reconcile timing): use systemd.user.startServices = "sd-switch" to apply service diffs automatically at activation time, and add a lightweight, non-invasive user-scope auditor timer/service that checks FragmentPath, DropInPaths, and NeedDaemonReload across all stack units and emits actionable alerts (and optionally runs systemctl --user daemon-reload). This avoids activation deadlocks by not attempting to rebuild generations from inside the user manager.

Policy defaults recommended:

    Issue 1: fail-closed for “restart/apply” (for automation correctness), while ensuring failures are obviously “apply failed, stack may still be running” via logs and a separate “status” probe.
    Issue 2: auto-heal (overwrite) for unit artifacts; block-and-alert for unexpected drop-ins.
    Issue 3: block-and-alert on provenance violations; auto-heal only via daemon-reload and “safe restart” when explicitly enabled.

Detailed risk analysis
Issue 1: Restart visibility ambiguity with oneshot + RemainAfterExit

Primary root causes

Oneshot services behave like short-lived “do something then exit” jobs. systemd documents that oneshot “is similar to exec,” but the manager considers the unit “up” after the main process exits; and RemainAfterExit= is “particularly useful” for oneshot services because it keeps the unit considered active after its processes exit. This is structurally at odds with “a container stack is healthy and serving traffic,” because:

    systemd is tracking the lifecycle of the compose command, not the containers’ processes;
    podman compose up -d returns when it has submitted the desired state and detached; it does not necessarily mean all containers are healthy at application level; and
    systemd explicitly notes that for RemainAfterExit=yes, invoking systemctl start again may take no action if the unit is already considered active, which can confuse operators who expect “start” to be an idempotent re-apply.

Podman auto-update adds a second semantic layer: it “restarts containers configured for auto updates” by restarting the systemd units they run in, and it even cautions that determining restart failure is best done via SDNOTIFY-based readiness; “without that, restarting the systemd unit may succeed even if the container has failed shortly after.” Your current model restarts a stack orchestrator unit (oneshot) that then manipulates containers, which is workable but makes Podman’s “restart success” semantics especially easy to misread as “stack is good.”

Failure-mode taxonomy

    False-positive success after restart
        Mechanism: systemctl --user restart stack.service returns success because ExecStart succeeded and systemd considers the unit active (exited), but one or more containers crash shortly after, or never became ready. systemd tracks the oneshot action, not the container health.
        Blast radius: automation (CI, cron, “update pipeline”) believes the update succeeded; Podman auto-update may mark update “true” and not roll back if the systemd restart appears successful.
        Detectability: low without explicit health checks; requires querying container status/health or building readiness gating into the unit.
        Operator impact: “green” systemd with real stack degradation; delayed incident detection.

    False-negative failure state while stack is still running
        Mechanism: prestart checks (secrets/env) fail and return non-zero; systemd marks unit failed, even though existing containers (from previous successful run) remain running. This is particularly likely if you add strict ExecStartPre checks that fail fast. systemd behavior: any of ExecStartPre, ExecStart, or ExecStartPost failing (without “-” prefix) makes the unit failed.
        Blast radius: monitoring mirrors systemd → pages even though service continues; auto-update rollbacks may trigger unnecessarily; operators may attempt panic remediation that actually causes an outage.
        Detectability: medium if you explicitly log “apply failed; existing containers unchanged” and provide a separate “runtime health” probe.
        Operator impact: confusion, wasted time, higher chance of operator-induced incidents.

    No-op “start” due to RemainAfterExit
        Mechanism: unit remains active after a prior successful run; a later “start” does nothing because systemd considers it already running (RemainAfterExit=yes “latches” active).
        Blast radius: human operators and automation expecting “start == apply” can silently skip applying changes (especially dangerous if a “fix” playbook runs start rather than restart).
        Detectability: high if you codify “start is ensure-latched; restart is apply,” and alert when start is used in automation.

    Degraded user manager
        Mechanism: the per-user systemd manager may not exist at boot or persist after logout unless linger is enabled. A user manager instance is created for logged-in users; user services keep running outside a session only if lingering is enabled.
        Blast radius: auto-update timer firing in user scope may not run; restarts requested by Podman auto-update may fail because there is no user manager to receive them.
        Detectability: medium—system-wide logs and loginctl state; but frequently mistaken for Podman failures.
        Operator impact: “works while logged in” class of outages.

Issue 2: Drift recovery gap for ~/.config/systemd/user unit artifacts

Primary root causes

Home Manager is designed to be conservative about overwriting existing user files. During activation, it runs collision checks (e.g., checkLinkTargets) and errors out if a file exists where Home Manager intends to place a managed symlink. The failure pattern is well documented in real activations: “Existing file ‘…’ is in the way…” and suggestions to move/remove or use backup options.

Critically, Home Manager’s own documentation emphasizes the activation DAG constraint: scripts that cause observable side effects must occur after writeBoundary, while checks like checkLinkTargets run earlier to prevent accidentally deleting user data. That means “auto-delete the drifted file during activation” is intentionally hard unless you opt into an overwrite policy.

Home Manager does provide an overwrite mechanism via per-file force. Community references show the intent clearly: force will unconditionally replace the target, deleting it regardless of whether it is a file or link. MyNixOS option listings also include .force for home.file targets.

Failure-mode taxonomy

    Activation hard-fail due to drift
        Mechanism: a managed unit file symlink is replaced with a local file; next activation detects collision and fails before applying any changes.
        Blast radius: prevents rolling out updated unit definitions, container images, or timers; can also block system-level nixos-rebuild switch flows when Home Manager is used as a NixOS module, because the associated Home Manager activation service fails.
        Detectability: high (explicit activation error).
        Operator impact: manual cleanup required; may be remote-host hostile.

    Backup-based drift handling fails due to backup collisions
        Mechanism: backupFileExtension/-b workflow can fail if a backup target already exists (“file.old would be clobbered…”), leaving you back at a hard failure.
        Blast radius: intermittent failures; operator toil increases because “the backup fix” isn’t stable under repeated churn.
        Detectability: high (explicit error).
        Operator impact: fatigue; higher chance of “just delete it” unsafe behavior.

    Silent provenance break if drift prevents updates but old units continue running
        Mechanism: activation fails, but previously-enabled units continue running with old definitions; container auto-update may keep restarting the old behavior. This can create a split-brain where declarative config says one thing; runtime keeps another.
        Blast radius: surprises during incident response; irreproducible state.
        Detectability: medium: requires explicit checks of FragmentPath, hashes, and Home Manager activation failure signals.

Issue 3: Reconciliation timing ambiguity for no-op rebuilds and stale load state

Primary root causes

There are two distinct reconciliation layers:

    Filesystem reconciliation: ensure ~/.config/systemd/user/<stack>.service exists and matches the Home Manager generation (not replaced, not missing).
    systemd load reconciliation: ensure the user manager has reloaded unit metadata and is using the expected unit file; systemd exposes FragmentPath (“the unit file path this unit was read from”) and NeedDaemonReload to indicate that the file changed since last load.

Because systemd has a defined user unit load path where earlier directories override later ones, the presence/absence of the unit in ~/.config/systemd/user is decisive: if the unit disappears or is replaced incorrectly, systemd can fall back to another path (including /etc/systemd/user).

Home Manager’s behavior at activation time also matters. It has an explicit option systemd.user.startServices controlling whether changed/obsolete services are automatically started/stopped after activation, including an automatic mode using sd-switch (“determines the necessary changes and automatically apply them”). If this is not enabled, “successful activation” may still require manual systemctl --user operations to fully reconcile running services.

Failure-mode taxonomy

    No-op rebuild does not repair drift
        Mechanism: if a “rebuild” does not run a Home Manager activation step (or runs one that does not rewrite links), drifted files remain and invariants are not restored. This is particularly damaging because operators reasonably assume “rebuild == reconcile.”
        Blast radius: continued sourcing of wrong unit files; drift accumulates; autoupdate can keep amplifying the wrong behavior.
        Detectability: medium unless you explicitly audit FragmentPath and the file type (symlink vs regular) of the unit file.
        Operator impact: seeming randomness: “sometimes rebuild fixes it, sometimes not.”

    Stale loaded units and stale drop-ins
        Mechanism: systemd can keep a loaded configuration; changes to FragmentPath/SourcePath set NeedDaemonReload=true, signaling that a reload is recommended. If you don’t reload, behavior may remain anchored to prior load state.
        Mechanism (drop-ins): even if the main unit fragment comes from ~/.config/systemd/user, drop-ins can be sourced elsewhere; systemd exposes DropInPaths, and real systemctl show output demonstrates drop-ins coming from /etc/....
        Blast radius: unexpected overrides (env, exec lines, dependencies) cause “it’s running but not the config I wrote.”
        Detectability: high if you routinely inspect DropInPaths and use systemctl show -p FragmentPath.
        Operator impact: “ghost overrides” and slow root cause analysis.

    User manager not up (or unstable) at the time reconciliation is expected
        Mechanism: user services usually run only while the user is logged in unless linger is enabled; your homelab likely expects boot-time availability.
        Blast radius: reconciliation timers don’t fire; auto-update doesn’t fire; stack availability becomes session-dependent.
        Detectability: medium (depends on system-level log access).
        Operator impact: inconsistent service uptime.

Option matrix
Issue 1: Restart visibility ambiguity
Option	What changes	Safety (false success/false fail)	Complexity	Compatibility with current model	Rollback burden
Keep oneshot; improve observability only	Standardize operator guidance (“restart, then verify”); add richer logging and a stackctl status command; do not gate success on readiness	Low safety: still vulnerable to “restart success but stack unhealthy” because oneshot success is only command success 	Low	High	Very low
Keep oneshot; add ExecStartPost readiness gate + strict exit codes	Add bounded health/readiness checks in ExecStartPost, and fail service if not running/healthy; preflight checks in ExecStartPre or wrapper; rely on systemd rule that any ExecStartPre/Start/Post failure makes unit failed 	High safety for automation; may introduce “unit failed but old containers still running” if preconditions fail	Medium	High (still oneshot + RemainAfterExit)	Low
Convert to Type=notify “latch keeper” wrapper	Keep user-scope service, but make unit long-running and only declare READY after checks; aligns with Podman guidance that readiness matters for detecting failure 	Highest safety and best semantics; requires maintaining a small resident wrapper process	Medium-high	Medium (changes unit semantics; still triggers podman compose up -d)	Medium
Issue 2: Drift recovery gap
Option	What changes	Safety (data loss vs availability)	Complexity	Compatibility	Rollback burden
Fail-closed + alert	Keep current behavior; add drift detection and paging; require manual cleanup when conflict occurs; relies on Home Manager’s collision checks prior to write boundary 	Safe for user data, risky for availability because activation can hard-fail	Low-medium	High	Low
Use home-manager.backupFileExtension for conflicts	Configure automatic rename of conflicting files instead of failing (“move existing files by appending extension rather than exiting with an error”) 	Good availability, but risk of backup collisions (“would be clobbered”) and backup sprawl 	Low	High	Low
Strong enforcement via per-file .force = true for unit artifacts	Mark the unit artifacts as “overwrite allowed,” letting activation repair drift by replacing the target (even if it’s a local file); community notes warn this deletes regardless of file/link 	High availability; intentional data loss is constrained to “owned artifacts”	Medium	High	Low-medium
Issue 3: Reconciliation timing ambiguity
Option	What changes	Safety	Complexity	Compatibility	Rollback burden
Manual reconciliation	Document/require systemctl --user daemon-reload and service restarts; optionally rely on NeedDaemonReload checks only when debugging 	Operator-dependent; brittle under automation	Low	High	Very low
Enable systemd.user.startServices = "sd-switch"	Let Home Manager automatically start/stop/reload changed services at activation time; sd-switch automatically applies necessary changes 	Good activation-time reconciliation; still depends on activation actually running	Low-medium	High	Low
Add user-scope audit timer for provenance + reload health	Add a user *.timer + oneshot audit service that periodically checks FragmentPath, DropInPaths, NeedDaemonReload; can auto-run daemon-reload and alert on provenance violations; uses systemd properties and path-based activation patterns 	Highest robustness without rebuild recursion; requires linger to be reliable 	Medium	High	Low-medium
Final recommendations
Issue 1 preferred approach: Keep oneshot, but make “restart == verified apply”

Recommendation

Adopt the “oneshot + verification gate” pattern: keep Type=oneshot and RemainAfterExit=true, but treat systemctl --user restart <stack>.service as an apply-and-verify transaction by adding:

    ExecStartPre= (or wrapper-in-ExecStart) for deterministic preflight checks (secrets/env sanity, compose file presence, registry reachability, lock acquisition).
    ExecStart= for podman compose up -d --remove-orphans.
    ExecStartPost= for a bounded readiness check that fails if containers are not running (and optionally not healthy) within a timeout.

Systemd’s semantics are explicit: ExecStartPost runs only after ExecStart is invoked successfully for oneshot (i.e., the last ExecStart= exited successfully), and failure in ExecStartPre/Start/Post causes the unit to be considered failed. This is the cleanest way to make the exit status of systemctl restart meaningful for automation, and it also improves Podman auto-update rollback correctness because Podman notes that restart success can otherwise be a false positive.

Policy choice

    Fail-closed for apply/restart. A restart that cannot verify readiness should return non-zero and set the unit to failed. This is the only robust automation contract given Podman’s warning about false-positive restart success.
    Mitigation for “stack still running but unit failed”: log explicitly and provide a dedicated stackctl runtime-status probe so operators can quickly distinguish “apply failed” from “outage.”

Issue 2 preferred approach: Auto-heal drift for unit artifacts via per-file force

Recommendation

Use strong enforcement for the unit artifacts only: set .force = true on the Home Manager-managed files that constitute your ownership invariant (the unit file itself and any .d/ drop-ins you own). The Home Manager ecosystem explicitly recognizes .force as the mechanism to avoid the “existing file is in the way” foot-gun; it is described as unconditionally replacing the target (deleting regardless of file or link).

This choice directly eliminates the “activation deadlock” class of drift: even if the symlink is replaced by a local file, the next activation overwrites it instead of failing at checkLinkTargets. This aligns with Home Manager’s activation model where collision checks occur early, and thus overwrite intent must be declared up front.

Policy choice

    Auto-heal (overwrite) for owned artifacts. Your invariant explicitly says “no effective stack unit definition should be sourced from /etc/systemd/user for migrated units,” which is incompatible with allowing manual edits to the owned unit file. Overwrite is the correct policy.
    Keep fail-closed (no overwrite) for non-owned home files; do not globally enable destructive overwrite because it increases the chance of deleting legitimate user state.

Issue 3 preferred approach: Activation-time reconciliation plus continuous provenance auditing

Recommendation

Do two things:

    Set systemd.user.startServices = "sd-switch" so Home Manager activations automatically start/stop/reload systemd user services and stop obsolete services from the previous generation.
    Add a user-scope audit timer/service that periodically validates provenance and load freshness:
        FragmentPath must be under ~/.config/systemd/user for migrated units (as per your invariant).
        DropInPaths must not include unexpected /etc/systemd/user/... drop-ins for migrated units (otherwise you have stale override risk).
        NeedDaemonReload must be false, or the auditor should run systemctl --user daemon-reload and re-check. systemd explicitly defines NeedDaemonReload and FragmentPath semantics.

This avoids two fragile patterns: (a) depending on no-op rebuild behavior for drift repair, and (b) trying to rebuild Home Manager generations from inside user services (a common source of deadlocks and recursion).

Policy choice

    Block-and-alert on provenance violations; auto-heal only safe reload operations. Auto-heal should be limited to daemon-reload and (optionally) reset-failed, not to rebuilding generations or deleting arbitrary files.

Implementation plan
Systemd and provenance primitives to standardize on

These diagnostics are the foundation for both enforcement and validation:

    Unit provenance: FragmentPath is the unit file path the unit was read from.
    Load freshness: NeedDaemonReload indicates the configuration file the unit is loaded from (FragmentPath/SourcePath) changed since the configuration was read, and reload is recommended.
    Drop-ins: DropInPaths exposes where override fragments are sourced.
    User unit load order: ~/.config/systemd/user appears before /etc/systemd/user in the user unit load path, and earlier directories override later ones; you can also print the active unit paths with systemd-analyze --user unit-paths.
    Practical query method: systemctl show -p FragmentPath <unit> is a standard way to locate a unit’s source file.

Issue 1 implementation: Make restart outcomes unambiguous
Pattern A: Verified-apply oneshot

A concrete unit structure (illustrative; adapt paths and naming):

ini

[Unit]
Description=Homelab stack: foo (rootless Podman Compose)
After=default.target

[Service]
Type=oneshot
RemainAfterExit=true

# 1) Preflight checks: do not modify the stack, only validate inputs and acquire a lock.
ExecStartPre=/nix/store/...-stackctl/bin/stackctl preflight foo

# 2) Apply desired state.
ExecStart=/nix/store/...-stackctl/bin/stackctl apply foo

# 3) Verify state is actually achieved (bounded wait for "running" and optionally "healthy").
ExecStartPost=/nix/store/...-stackctl/bin/stackctl verify foo --timeout=60s

# Optional hardening:
TimeoutStartSec=120

This design uses systemd’s documented rules that (a) ExecStartPost runs only after ExecStart succeeded for oneshot, and (b) failure in ExecStartPre/Start/Post causes unit failure.
The stackctl contract

stackctl should be the single source of truth for exit codes and journald messaging:

    stackctl preflight:
        verification of required secret files/env files (existence, permissions),
        verification that the compose file path exists,
        lock acquisition (e.g., flock on a per-stack lock) to prevent concurrent operator restart vs auto-update restart.
    stackctl apply:
        run podman compose up -d --remove-orphans with explicit project name and deterministic file set.
    stackctl verify:
        query expected container set (label filter tied to compose project),
        ensure each is running,
        if healthchecks exist, optionally wait for healthy,
        fail after timeout.

This directly addresses Podman’s auto-update warning about restart success not implying the workload is actually running/ready.
Policy knob: preserve “start is no-op” but make “restart” authoritative

Keep the semantic rule: start = ensure-latched; restart = apply. systemd explicitly notes that for RemainAfterExit=yes, calling systemctl start again may take no action. That is acceptable as long as your tooling and automation always uses restart for apply and uses your verification gate.
Issue 2 implementation: Auto-heal drift without failing activation
Preferred: per-file overwrite for unit artifacts

For the specific unit files and drop-ins you consider “owned,” enable overwrite. The Home Manager community references show .force exists and is intended for cases where external software overwrites managed files; it will replace the target even if it is a file or link.

Implementation has two common shapes:

    If you manage unit files via xdg.configFile or home.file, set:
        xdg.configFile."systemd/user/foo.service".force = true; or
        home.file.".config/systemd/user/foo.service".force = true;

MyNixOS option listings confirm .force exists for managed files.
Backup option as a secondary safety net

If you have a strong requirement to preserve overwritten local files, home-manager.backupFileExtension is the conservative mechanism: it moves existing conflicting files aside by appending an extension rather than failing.

However, treat it as a secondary mechanism because backup workflows can themselves fail when a backup file already exists (“would be clobbered”), and this can reintroduce activation deadlocks and operator toil.
Issue 3 implementation: Deterministic reconciliation without deadlocks
Activation-time service reconciliation

Enable Home Manager’s systemd service reconciliation:

    systemd.user.startServices = "sd-switch";

This option exists specifically to “start new or changed services that are wanted by active targets” and “stop obsolete services” after activation; sd-switch is described as automatically determining and applying necessary systemd changes.

This reduces the chance of “unit file on disk changed but service not restarted.”
Continuous provenance and freshness auditing via user timers

Add a user-scope auditor:

    homelab-provenance-audit.service (oneshot)
    homelab-provenance-audit.timer (e.g., every 5–15 minutes)

Use systemd’s own properties:

    FragmentPath to verify the unit is loaded from ~/.config/systemd/user.
    DropInPaths to detect unexpected legacy drop-ins.
    NeedDaemonReload to detect stale-loaded units and optionally trigger daemon-reload.

This auditor should not attempt to rebuild Home Manager generations (to avoid recursion), but it can safely run:

    systemctl --user daemon-reload if NeedDaemonReload=yes
    systemctl --user reset-failed <unit> when appropriate
    emit structured logs and (optionally) exit non-zero to integrate with alerting pipelines

Optional: path-based activation for on-disk drift signals

If you want faster detection than polling, systemd supports path-based activation using .path units. In user scope, you can monitor:

    ~/.config/systemd/user/foo.service
    ~/.config/systemd/user/foo.service.d/

and trigger the auditor immediately when changes occur. This helps catch manual edits quickly and ensures daemon-reload happens promptly.
Cross-cutting: Ensure user manager availability for a homelab

Because your stacks and timers run in user scope, you must treat “user manager availability” as a hard dependency:

    systemd starts separate user manager instances for logged-in users.
    user services run only while logged in unless linger is enabled; linger causes a user manager to be created at boot and persist beyond sessions.

In NixOS terms, make linger declarative for the service account that owns the stacks (implementation detail depends on your NixOS user config pattern).
Validation plan
Deterministic local test matrix

The goal is to validate: (a) restart semantics, (b) drift handling, (c) reconciliation under stale user manager state, (d) Podman auto-update integration.

For each test, collect:

    systemctl --user show <unit> -p FragmentPath -p DropInPaths -p NeedDaemonReload -p ActiveState -p SubState -p Result -p ExecMainStatus (authoritative properties; FragmentPath and NeedDaemonReload semantics are defined by systemd).
    journalctl --user -u <unit> for the apply/verify logs.
    podman auto-update --dry-run and podman auto-update output; Podman documents the UPDATED field and that it restarts the systemd unit executing the container.
    podman ps / podman inspect fields relevant to health and labels.

Restart semantics

    Preflight failure
        Induce: remove required secret/env file.
        Execute: systemctl --user restart stack.service.
        Pass/fail:
            PASS: systemctl returns non-zero; unit ActiveState=failed and journal explains missing secret; containers from previous run remain present (verified via podman ps).
            Confirm ExecStartPre/ExecStartPost failure causes unit failure (systemd documented behavior).

    Apply success + verify success
        Induce: all dependencies present.
        Execute: systemctl --user restart stack.service.
        Pass/fail:
            PASS: exit code 0; ActiveState=active, SubState=exited for oneshot; verify log indicates all containers running/healthy. (Oneshot/RemainAfterExit semantics documented.)

    Apply “succeeds” but verify fails
        Induce: break a container so it immediately exits or becomes unhealthy.
        Execute: restart.
        Pass/fail:
            PASS: unit fails in ExecStartPost path; automation sees failure exit; aligns with systemd rule that failing start/post fails the unit.

Drift handling

    Replace symlink with local file
        Induce: overwrite ~/.config/systemd/user/stack.service with a regular file.
        Execute: Home Manager activation (the same mechanism you use in production, e.g., via nixos-rebuild switch).
        Pass/fail:
            PASS (with .force=true): activation does not fail; file restored to managed form; unit FragmentPath still resolves under ~/.config/systemd/user. (FragmentPath definition is explicit.)
            FAIL (without .force): reproduce “Existing file … is in the way” during checkLinkTargets.

Reconciliation timing

    Stale loaded unit
        Induce: change the unit file on disk and do not run daemon-reload.
        Validate:
            NeedDaemonReload=yes should appear.
        Execute: run auditor; auditor runs systemctl --user daemon-reload.
        Pass/fail:
            PASS: after auditor, NeedDaemonReload=no, and subsequent restart uses the new unit behavior.

    Stale drop-in
        Induce: create a legacy drop-in in /etc/systemd/user/stack.service.d/override.conf.
        Validate:
            DropInPaths includes the path.
        Pass/fail:
            PASS: auditor alerts (and optionally fails) because drop-ins violate ownership invariant even if FragmentPath is correct.

Podman auto-update integration

    Dry run behavior
        Execute: podman auto-update --dry-run --format "{{.Image}} {{.Updated}}".
        Pass/fail: output shows pending when updates exist (documented).

    End-to-end update triggers correct unit
        Induce: push a new image to your controlled local registry.
        Execute: podman auto-update.
        Pass/fail:
            PASS: Podman reports the expected UNIT for the container and restarts it; Podman documents that it restarts the systemd unit executing the container when an image is updated.

    Rollback correctness under failed restart
        Induce: make verification fail after update (e.g., health check fails).
        Execute: podman auto-update with default rollback behavior.
        Pass/fail:
            PASS: auto-update detects failure to restart and rolls back (Podman documents rollback behavior and the caveat about readiness detection).

Production-host validation

Production patterns should emphasize signals, not hope:

    Daily provenance report
        Use auditor output to produce a daily “all stacks provenance OK” signal.
        If any unit fails invariants:
            FragmentPath not under ~/.config/systemd/user (violation; indicates fallback to other unit path).
            unexpected DropInPaths under /etc/systemd/user (stale override).
            NeedDaemonReload=yes beyond a grace period (stale load state).

    Alerting requirements
        Page on:
            verification-gated restart failures (Issue 1), because they imply “desired state not achieved.”
            provenance violations (Issue 3), because they imply loss of declarative authority.
        Ticket (non-page) on:
            repeated drift repairs (Issue 2) to identify the drift source.

Rollback and recovery plan
Staged rollout sequence

Because user unit load order favors ~/.config/systemd/user over /etc/systemd/user, you can stage changes safely while keeping an escape hatch.

    Stage 1: Observability first
        Deploy the auditor service/timer in user scope.
        Deploy stackctl status tooling (read-only).
        No change in restart semantics yet; measure current false-positive rate.

    Stage 2: Enable reconciliation (sd-switch)
        Enable systemd.user.startServices = "sd-switch" so activations reconcile services automatically.
        Validate on a canary host that activations do not cause unexpected restarts beyond what you intend.

    Stage 3: Drift auto-heal for unit artifacts
        Set .force=true only for unit artifacts.
        Validate drift scenario: replace a unit file with local file; confirm activation does not fail.

    Stage 4: Verified-apply restarts
        Introduce ExecStartPost verification gates and deterministic exit codes.
        Validate Podman auto-update rollback flow (your controlled registry test) again under the new gating logic.

Recovery playbooks by failure mode

Failure mode: unit unexpectedly sourced from /etc/systemd/user

    Symptoms
        Auditor flags FragmentPath not under ~/.config/systemd/user.
    Immediate recovery
        Run systemctl --user daemon-reload and re-check FragmentPath. (NeedDaemonReload/reload semantics are explicit.)
        Ensure the file exists under ~/.config/systemd/user and is not masked.
    Root cause isolation
        Print effective user unit paths: systemd-analyze --user unit-paths.
        Check for missing file, wrong name, or removed file due to drift.

Failure mode: activation fails due to file collisions

    Symptoms
        Home Manager service shows “Existing file … is in the way…” during checkLinkTargets.
    Immediate recovery
        If .force=true is not yet deployed for the file, temporarily move the file aside manually and rerun activation.
        If using backups, watch for backup collisions (“would be clobbered”); if encountered, delete/rename the conflicting backup and rerun.
    Long-term fix
        Enable .force=true for the artifact category that is expected to be immutable (unit files and owned drop-ins).

Failure mode: restart succeeds but service is actually down

    Symptoms
        Containers not running/healthy, but unit shows active (exited) and restart returned 0 (pre-gating scenario). Oneshot state doesn’t imply workload health.
    Immediate recovery
        Manually run stackctl verify (or equivalent) and restart with systemctl --user restart.
    Long-term fix
        Deploy ExecStartPost readiness gating so this becomes a “restart failed” event instead of silent success.

Failure mode: user manager not running (timers/services not firing)

    Symptoms
        User timers not running; stacks only run while logged in.
    Immediate recovery
        Log in and start user services.
    Long-term fix
        Enable linger for the service account so the user manager exists at boot and persists; system documentation and common guidance note this requirement for non-interactive user services.

---

## nixosconfig-7v9 — Decision: Home Manager user unit ownership model

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

# Decision: Home Manager Ownership for Stack User Units

**Date:** 2026-02-13  
**Status:** Accepted (implementation in code complete; rollout pending)  
**Scope:** Stack lifecycle user units (`${stackName}.service`)  
**Primary research:** [home-manager-user-service-migration-research-2026-02.md](../research/home-manager-user-service-migration-research-2026-02.md)  
**Related incident:** [2026-02-13-compose-change-propagation-test.md](../incidents/2026-02-13-compose-change-propagation-test.md)

## Context

`igpu` propagation testing showed a reproducible failure class where stale unit files under `~/.config/systemd/user` override updated stack units generated by NixOS under `/etc/systemd/user`.

This is consistent with user unit search path precedence and explains why `systemctl --user daemon-reload && systemctl --user restart <unit>` can continue executing stale definitions when a higher-precedence unit file remains present.

## Decision

1. Keep stack lifecycle in user scope (no move to system service ownership).
2. Migrate stack unit ownership from NixOS `/etc/systemd/user` generation to Home Manager `systemd.user.services` generation.
3. Enforce single ownership for each stack unit name (no simultaneous definitions across `/etc/systemd/user` and `~/.config/systemd/user`).
4. Add post-switch ownership assertions using:
   - `systemctl --user show <unit> -p FragmentPath -p DropInPaths`
5. Treat "user manager unavailable/unreachable" as a reconciliation failure signal that must be surfaced explicitly.

## Rationale

1. This migration materially mitigates the exact ownership-collision failure observed in production-style testing.
2. It keeps lifecycle control in user scope, preserving current Podman auto-update model and labeling invariants.
3. It does not assume Home Manager is a universal cure; user-manager availability and drop-in drift remain explicit residual risks and are included in Phase 2.5 test gates.

## Consequences

### Positive

1. Eliminates the most likely `/etc` vs `~/.config` shadowing collision for stack unit definitions.
2. Clarifies stack-unit source of truth.
3. Aligns unit ownership with user-scoped control plane behavior.

### Residual Risks

1. Home Manager skips service switching if user systemd manager is not running/reachable.
2. User-level drop-ins and transient/control paths can still alter effective unit behavior.
3. Migration must include cleanup of old ownership artifacts to avoid transitional conflicts.

## Implementation Link

- Active implementation plan: `docs/podman/current/phase2.5-home-manager-migration-plan.md`

---

## nixosconfig-cpf — Quality gate: run at feature boundaries not every commit

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Decision: Don't run 'check' after every small change — it's slow and kills momentum. Run 'check' when a feature feels complete. Run 'check --full' before pushing. 'nix fmt' is cheap and fine anytime. Trust the code while iterating; validate when landing.

---

## nixosconfig-n2u — Reference: Special Host Configurations (doc1/igpu/framework)

- **Status:** closed
- **Type:** chore
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Reference documentation for special host configurations.

## doc1 (Main Services VM)
- Serves as Nix cache server (nixcache.ablz.au)
- Runs GitHub Actions runner (proxmox-bastion)
- Hosts 20+ Docker services
- MTU 1400 for Tailscale compatibility

## igpu (Media Transcoding)
- AMD 9950X iGPU passthrough
- Latest kernel for GPU support
- Increased inotify watches (2,097,152)
- Vendor-reset DKMS module on Proxmox host

## framework (Laptop)
- Sleep-then-hibernate configuration
- Fingerprint reader support
- Power management optimizations

---

## nixosconfig-ym0 — Reference: Standard Kuma Health Endpoints

- **Status:** closed
- **Type:** chore
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Reference documentation for standard Uptime Kuma health check endpoints.

## Standard Kuma Health Endpoints

- Immich: `/api/server/ping`
- Plex: `/identity`
- Mealie: `/api/app/about`
- Jellyfin: `/System/Info/Public`
- Smokeping: `/smokeping/smokeping.cgi`
- Others: keep `/` unless a documented unauthenticated endpoint exists.

---

## nixosconfig-5s4 — Phase 4: Clean up compose files and verify backend (podman)

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Final cleanup tasks for podman compose migration.

## Tasks

1. **Remove deprecated version key:**
   - Find all compose files with version: "3.8"
   - Remove the key (docker-compose warns it's obsolete)

2. **Add missing health checks:**
   - Audit all containers for health checks
   - Add health checks where missing
   - Improves --wait reliability

3. **Ensure fully-qualified images:**
   - All images must be fully-qualified (required for auto-update registry policy)
   - Format: registry.example.com/org/image:tag

4. **Remove orphaned compose files:**
   - Clean up compose files for disabled/removed stacks

5. **Verify database backend:**
   - Check if using BoltDB or SQLite
   - Migrate to SQLite if needed (ahead of Podman 6.0)
   - Command: podman info --format "{{.Store.GraphDriverName}}"

## Files

- stacks/**/docker-compose.yml (all compose files)

## Reference

docs/podman-compose-failures.md Part 5, Phase 4

---

## nixosconfig-7da — Configure HA cover entity combining Shelly + tilt sensor

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Create a template cover entity in Home Assistant that combines the Shelly relay (for control) and tilt sensor (for state). Should expose open/close/stop actions and report current position (open/closed).

---

## nixosconfig-c22 — Package unifi-mcp for PyPI + MCP Registry

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Same pattern as pfsense-mcp: add unifi_mcp/ package dir, __init__.py, __main__.py, copy generated/server.py, update pyproject.toml with full metadata + console_scripts, create server.json (io.github.abl030/unifi-mcp), add mcp-name comment to README, build + publish.

---

## nixosconfig-ftw — Install and wire Shelly Gen 4 to garage door opener

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Physical installation of Shelly Gen 4 relay. Wire to garage door opener motor (dry contact relay to trigger open/close). Connect to WiFi and add to Home Assistant via Shelly integration. Verify relay toggles the door.

### Notes

## Hardware Change: Shelly → MHCOZY ZG-001

### Why
- Shelly 1 Gen 4 ANZ is 240V AC only — no DC input support
- Don't want live 240V hanging in the garage door opener
- Merlin MT100EVO has 30V DC accessory output — need a DC-powered relay

### New Device: MHCOZY ZG-001
- 1 Channel Zigbee 3.0 Smart Relay Switch
- Model: ZG-001 (Amazon AU ASIN: B08X218VMR)
- Power: DC 5-32V (will run off Merlin's 30V DC accessory output)
- Dry contact relay with NO/NC/COM terminals
- Inching mode (momentary pulse, adjustable, default 1s) — set to 0.4-1.0s for MT100EVO
- Selflock mode also available (not needed here)
- Built-in 433MHz RF receiver (bonus, not required)
- Confirmed working with Zigbee2MQTT and Home Assistant
- Pairs to existing SLZB-06P7 coordinator
- Status: ORDERED, waiting for delivery

### Shelly 1 Gen 4 ANZ
- Returning — AC only, not suitable for this use case

---

## MT100EVO Terminal Block (confirmed)

| Terminal | Label | Wire | Function |
|----------|-------|------|----------|
| **1** | Push Button | Red (+ve) | Dry contact input for wired wall button |
| **2** | Ground | White (-ve) | Common ground (shared with IR beam input) |
| **0** | E-Serial | — | Security+ 2.0 protocol (not used) |

- Ships with green test button bridging T1 and T2
- Shorting T1-T2 momentarily toggles door: open → close → stop
- **30V DC accessory output** (up to 50mA) — enough to power the MHCOZY
- **IMPORTANT**: 30V DC output is disabled in 'Low Standby Mode' — must turn that setting OFF in opener menu
- **Pulse duration: 0.4–1.0 seconds** — longer (~2s) causes double-command interpretation (door lurches then stops)

---

## Wiring Plan: MHCOZY ZG-001 → Merlin MT100EVO

### Power
- DC+ and DC- from Merlin's 30V DC accessory output to MHCOZY power input
- Within MHCOZY's 5-32V DC range

### Relay Output
- COM and NO to MT100EVO Terminal 1 and Terminal 2
- Wired in parallel with existing wall button — both continue to work

### MHCOZY Configuration
- Set to inching mode (momentary) ~0.5-1.0 second pulse
- Pair via Z2M (Zigbee 3.0)

### Materials Needed
- Twin-core signal wire (bell wire / 0.5mm) for relay output to T1/T2
- Short wire for DC power from Merlin accessory terminals
- Screwdriver, wire strippers

---

## HA Integration Plan (for when relay arrives)

Template cover entity combining relay + tilt sensor:
- Control: switch entity from MHCOZY via Z2M
- State: binary_sensor.garage_door_tilt_contact (already working)
- Conditions prevent toggle when already in desired state
- Automations: notify if open >10min, auto-close at night

---

## References
- HA Community: https://community.home-assistant.io/t/mhcozy-zigbee-dry-contact-relay-for-lights-garage-opener-etc/419210
- Amazon AU: https://www.amazon.com.au/MHCOZY-Adjustable-Self-Flock-Momentary-SmartThings/dp/B08X218VMR
- SmartHomeScene review: https://smarthomescene.com/reviews/zigbee-dry-contact-relay-review/
- MT100EVO terminals: https://community.garadget.com/t/merlin-mt100evo-cyclone-pro-mt120evo/4194
- MT100EVO manual: https://garagedooropenerremotes.com.au/wp-content/uploads/2017/08/MT100EVO-Tiltmaster-manual-114D4626G.pdf

---

## nixosconfig-mc2 — Publish MCP servers to PyPI + official MCP Registry

- **Status:** open
- **Type:** feature
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Publish all our MCP servers (pfsense, unifi, loki, lidarr) to PyPI and register them on the official MCP Registry (registry.modelcontextprotocol.io). Each server needs: (1) pfsense_mcp/ package dir with __init__, __main__, bundled server.py (2) pyproject.toml with full PyPI metadata + console_scripts entry point (3) server.json for MCP registry with io.github.abl030/ namespace (4) mcp-name HTML comment in README for PyPI validation (5) uv build + uv publish to PyPI (6) mcp-publisher login github + mcp-publisher publish to registry. Also submit PRs to awesome-mcp-servers lists and mcpservers.org for visibility.

---

## nixosconfig-wrw — Garage Door: Shelly Gen 4 + tilt sensor integration

- **Status:** open
- **Type:** epic
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Install and integrate garage door automation:
- Shelly Gen 4 relay to control garage door opener
- Tilt sensor for open/closed state detection
- Home Assistant integration (cover entity with open/close/state)
- Automations: auto-close timer, notifications, dashboard card

---

## nixosconfig-cp3 — Garage door automations and dashboard

- **Status:** open
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Set up automations:
- Auto-close after N minutes if left open
- Notification when door opens/closes
- Dashboard card showing state with open/close button
- Optional: night-time check automation (notify if open at bedtime)

---

## nixosconfig-yof — Build NZBGet MCP server

- **Status:** open
- **Type:** feature
- **Priority:** 3
- **Created:** 2026-02-24

### Description

MCP server for NZBGet Usenet download client. Needed for download visibility and sending NZBs directly.

API docs: https://nzbget.com/docs/api/ (JSON-RPC)
Host: nzbget.ablz.au:443 (HTTPS, behind reverse proxy)

Tools needed: get_status, list_downloads, get_history, add_nzb_url.

See docs/music-pipeline-postmortem.md for context — NZBGet path mapping gap caused manual file copying.
Parent epic: nixosconfig-z95 (music pipeline)

---

## nixosconfig-eth — Phase 1: Beads (procedural memory)

- **Status:** closed
- **Type:** epic
- **Priority:** 1
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Package bd binary, configure hooks, deploy fleet-wide. COMPLETED. See docs/beads-rollout-plan.md.

---

## nixosconfig-41p — Package episodic-memory for NixOS

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Node.js app with native modules (better-sqlite3, sqlite-vec). Needs: buildNpmPackage or similar, handle native compilation, pre-cache HuggingFace ONNX model (all-MiniLM-L6-v2, ~22MB) in Nix store. Storage at ~/.config/superpowers/conversation-archive/ + conversation-index/db.sqlite.

---

## nixosconfig-bta — Install tilt sensor on garage door

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Physical installation of the tilt sensor on the garage door panel. Pair/add to Home Assistant (ZHA or Zigbee2MQTT depending on protocol). Verify open/closed state reporting is reliable.

### Notes

Sensor: Third Reality garage door tilt sensor (Zigbee)

## Progress
- Sensor: Third Reality garage door tilt sensor (Zigbee)
- Paired via Zigbee2MQTT (SLZB-06P7 coordinator)
- Original device ID: 0xffffb40e0601d2b5
- Renamed to: garage_door_tilt
- Entities created:
  - binary_sensor.garage_door_tilt_contact (door open/closed)
  - binary_sensor.garage_door_tilt_battery_low (battery status)
- Pairing method: mqtt.publish to zigbee2mqtt/bridge/request/permit_join

## Sensor Behaviour
- Very sensitive tilt detection — reports 'open' even at ~10% open
- Binary only (open/closed), no percentage tracking
- Good for security/notification use — won't miss a partially open door
- Mounted and tested: open/closed transitions confirmed working

## DIP Switches
- 4-level adjustable sensitivity via DIP switches on the device
- DIP switch also controls audible beep on/off
- Useful for tuning sensitivity if getting false triggers or missed events

---

## nixosconfig-ycd — Set up Syncthing to sync episodic-memory DB across fleet

- **Status:** closed
- **Type:** feature
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Use Syncthing to share ~/.claude/episodic-memory/ SQLite database across all fleet hosts. This gives fleet-wide conversation memory without cloud sync. Considerations: (1) SQLite + Syncthing conflict handling (use Syncthing's conflict resolution or WAL mode), (2) Which hosts to include, (3) One-way vs bidirectional sync.

---

## nixosconfig-8ds — Phase 3: Semantic Memory (compressed learnings)

- **Status:** closed
- **Type:** epic
- **Priority:** 3
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Deploy compressed learning/observation layer. Currently evaluating claude-mem (BLOCKED by critical process leak #1010) or alternatives. This space is evolving fast. See docs/agentic-memory-options-comparison.md.

---

## nixosconfig-ge0 — Nixify ha-mcp package to avoid uvx version drift

- **Status:** closed
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

ha-mcp 6.7.0 broke silently when fastmcp 3.0.0 was released (show_cli_banner renamed to show_server_banner). Currently pinned fastmcp<3 in wrapper script as workaround. Should package ha-mcp as a nix derivation with pinned deps like we do for pfsense-mcp, unifi-mcp, lidarr-mcp, slskd-mcp, vinsight-mcp, and loki-mcp. This eliminates uvx runtime resolution entirely. Also consider nixifying the other uvx-based MCPs (mcp-nixos, prometheus-mcp-server, beads-mcp) for the same reason. Revert the fastmcp<3 pin once this is done.

---

## nixosconfig-1dc — Track upstream episodic-memory bug fixes

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Monitor github.com/obra/episodic-memory for fixes to: #47 (MCP stdout corruption from console.log in embeddings.ts), #53 (orphaned MCP server processes). These are blockers for deployment. Check periodically.

### Notes

Workaround: forked to abl030/episodic-memory with PRs #56 and #51 merged. No longer blocking deployment. Upstream tracking moved to nixosconfig-0sb.2 (P4 backlog).

---

## nixosconfig-c52 — Framework s2idle lid-open race condition analysis (Feb 2026)

- **Status:** closed
- **Type:** bug
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Notes

## Incident: Feb 18 2026 - Framework laptop appeared to crash during hibernate

### What happened
User opened lid, screen flashed briefly, went dark. User assumed crash and hard powered off.
It was NOT a crash - the system re-suspended within 1 second of resuming.

### Root cause: s2idle ACPI SCI re-arm race condition

The lid-open ACPI event (IRQ 9) arrived during an active timer wake cycle. The kernel's s2idle
wake discrimination logic (`acpi_s2idle_wake()` in `drivers/acpi/x86/s2idle.c`) dismissed the
lid event as spurious, re-armed the ACPI SCI, and went back to sleep for ~1 second. A different
interrupt (IRQ 7) then woke the system fully, but by then the lid-open event had been consumed.

logind never received a "Lid opened" input event, so it correctly re-evaluated
HandleLidSwitch=suspend-then-hibernate with lid-state=closed, and re-triggered suspend.

### Evidence from journalctl -b -1

```
# The triple-wake sequence showing the race:
Timekeeping suspended for 133.243 seconds
PM: Triggering wakeup from IRQ 9      ← likely the lid-open ACPI event
ACPI: PM: Rearming ACPI SCI for wakeup ← kernel dismissed it, went back to sleep
PM: Triggering wakeup from IRQ 9      ← another ACPI wake
ACPI: PM: Rearming ACPI SCI for wakeup ← dismissed again
Timekeeping suspended for 0.969 seconds
PM: Triggering wakeup from IRQ 7      ← something else finally woke it
ACPI: PM: Wakeup unrelated to ACPI SCI
PM: resume from suspend-to-idle       ← full resume, but lid event was lost

# logind saw no lid-open, re-triggered:
20:02:43 Operation 'suspend-then-hibernate' finished.
20:02:44 Suspending, then hibernating...     ← NO "Lid opened" between these
```

Compare to EVERY successful resume in boot -1 which has "Lid opened." logged.

### Current boot showed PM: Image not found (code -22)
Because the user hard powered off during the re-suspend/hibernate, there was no valid
hibernate image. This is expected, not a separate bug.

### Also observed (not directly related but useful context)

1. **BAT1 battery estimation broken**: `BAT1: Failed to update battery discharge rate, ignoring: Numerical result out of range` - appears on multiple wakes, may affect hibernate timing decisions.

2. **HibernateOnACPower=no behavior**: When on AC, HibernateDelaySec countdown never starts. System sits in s2idle indefinitely, waking every 3h for battery checks. This is by-design but means the laptop never hibernates when plugged in (Feb 18: 7 wake cycles over 18 hours, never hibernated).

3. **Feb 15 freeze failures**: `Failed to freeze unit 'user.slice': Connection timed out` followed by `Failed to put system to sleep. System resumed again: Device or resource busy` - happened twice, logind retried and succeeded on third attempt.

4. **Feb 17 amdgpu errors during hibernate**: vmalloc failure in dc_state_create_copy, flip_done timeouts, NFS server timeouts causing 34-second device freeze. Hibernate still succeeded.

5. **Old pstore crash (Jun 2025, kernel 6.15.2)**: btusb_suspend NULL deref during runtime PM - different bug, different kernel, kept in /var/lib/systemd/pstore/1750333820/.

### Config reference
- sleep config: modules/nixos/services/framework/sleep-then-hibernate.nix
- hibernate fixes: modules/nixos/services/framework/hibernate-fix.nix
- host config: hosts/framework/configuration.nix
- Kernel: 6.19.0, BIOS 03.18, systemd 258.3

### If this happens again
1. DON'T hard power off - just close and reopen the lid
2. Check journalctl -b -1 for the triple-wake pattern (IRQ 9 re-arm then IRQ 7)
3. Absence of "Lid opened" in logind logs confirms it's this race, not a crash
4. To debug further: `echo 'file s2idle.c +p' > /sys/kernel/debug/dynamic_debug/control` (needs root) to trace the wake discrimination logic
5. AMD PMC debug: /sys/kernel/debug/amd_pmc/s0ix_stats (needs root)

---

## nixosconfig-w1l — Reference: Hash-Based Drift Detection

- **Status:** closed
- **Type:** chore
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Reference documentation for hash-based drift detection.

## Hash-Based Drift Detection

NixOS's deterministic builds mean identical `system.build.toplevel` hashes guarantee identical systems. This repo uses hash comparison to verify refactors produce no unintended changes.

### Workflow

```bash
# Capture current hashes as baseline (done automatically by nightly CI)
./scripts/hash-capture.sh

# Run full quality gate + drift detection (slow)
check --full --drift

# After making changes, compare against baseline
./scripts/hash-compare.sh

# Quick summary only (no nix-diff details)
./scripts/hash-compare.sh --summary

# Check specific host
./scripts/hash-compare.sh framework
```

### Interpreting Results

- **MATCH**: Hash unchanged - pure refactor, no functional changes
- **DRIFT**: Hash differs - configuration changed, nix-diff shows what

The compare script runs through ALL hosts and reports ALL drift (doesn't bail on first issue).

### When Hashes Change

If `hash-compare.sh` shows drift:
1. Review the nix-diff output to understand what changed
2. If intentional: run `./scripts/hash-capture.sh` to update baselines
3. If unintentional: investigate and fix the regression

Baselines are automatically updated by the nightly `rolling_flake_update.sh` after successful builds.

---

## nixosconfig-cf3 — Publish pfsense-mcp to PyPI

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

PyPI packaging already done (pfsense_mcp/ package, pyproject.toml, server.json, mcp-name tag). Wheel builds at dist/. Steps remaining: (1) Create PyPI account + API token (2) uv publish dist/* (3) Verify pip install pfsense-mcp works (4) mcp-publisher login github (5) mcp-publisher publish (6) Verify on registry.modelcontextprotocol.io

---

## nixosconfig-9t3 — Reference: Home Assistant & Music Assistant Integration

- **Status:** open
- **Type:** chore
- **Priority:** 4
- **Created:** 2026-02-24

### Description

Reference documentation for Home Assistant MCP integration.

## Home Assistant

Uses [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) for smart home control. Usage notes:
- All tools are **deferred** — use `ToolSearch` with query `+homeassistant` to load them before calling.
- Tool names follow `ha_*` convention (e.g., `ha_call_service`, `ha_search_entities`, `ha_get_state`).
- Use `ha_search_entities` to find entities by name/area/domain.
- Device targeting uses `entity_id` for service calls.
- Supports fuzzy entity matching and media playback via Music Assistant.
- Auth: `HA_TOKEN` in sops-encrypted `secrets/mcp/homeassistant.env`.

## Music Assistant Playback (Preferred Method)

Always search first to get exact URIs, then play with the URI. This avoids fuzzy matching errors (e.g., playing "Mr. Peanut" track instead of "Peanut" album).

```python
# 1. Get Music Assistant config_entry_id (one-time lookup)
ha_get_integration(query="music_assistant")  # Returns entry_id

# 2. Search for the album/track
ha_call_service("music_assistant", "search", return_response=True, data={
    "config_entry_id": "01K3AS5H08FV1C1AAKEDAFDMB5",
    "name": "Peanut",
    "artist": "Otto Benson",
    "media_type": ["album"],
    "limit": 5
})
# Returns: {"albums": [{"uri": "spotify--xxx://album/123", "name": "Peanut", ...}]}

# 3. Play with exact URI
ha_call_service("music_assistant", "play_media",
    entity_id="media_player.kitchen_home_2",
    data={"media_id": "spotify--xxx://album/123", "media_type": "album"})
```

## Volume Control Quirk (Google Cast / Music Assistant)

- Use `volume_set` with explicit `volume_level` (0.0-1.0) — avoid `volume_up`/`volume_down`.
- Wait until playback is stable before changing volume — mid-transition volume changes can stop playback.
- If volume change stops playback, resume with `media_player.media_play` then retry.

---

## nixosconfig-ecj — Build custom slskd MCP server

- **Status:** in_progress
- **Type:** feature
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Need an MCP server for slskd (Soulseek client) to avoid podman exec / raw API calls.

Should expose:
- Download transfer status (active, completed, failed)
- Search Soulseek network
- Browse peer shares
- Connection status
- Download/upload statistics
- Share management

slskd has a full REST API at /api/v1/. Currently we're hitting it via podman exec wget which is terrible.
Parent epic: nixosconfig-z95 (music pipeline)

### Notes

Scaffold complete at https://github.com/abl030/slskd-mcp — OpenAPI spec (70 paths, 93 ops) pulled from temp container with SLSKD_SWAGGER=true. Generator skeleton matches lidarr-mcp pattern. Sprint 1 (generator core) is next.

---

## nixosconfig-yrd — Migrate Claude Code to official/community NixOS module

- **Status:** closed
- **Type:** task
- **Priority:** 0
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Manual npm install of episodic-memory plugin dependencies irreparably broke Claude Code. Current custom HM module (modules/home-manager/services/claude-code.nix) is fragile.

Plan:
1. Research: is there an official or community NixOS/HM module for Claude Code? Evaluate options.
2. Migrate from custom module to the chosen module.
3. Plumb in episodic-memory plugin/MCP but leave it DISABLED (no credits right now).
4. Rethink MCP server placement: repo-level (.mcp.json) vs home-directory level (~/.claude/).
5. Strip out arr and soulseek MCPs entirely — don't re-add them.

Key lesson: manual npm install inside the Nix store broke everything. The new approach must handle plugin deps properly.

### Notes

2026-02-11: Closed — keeping custom module, not migrating. See earlier notes for full rationale.

---

## nixosconfig-rlo — Phase 2: Split container services by privilege

- **Status:** closed
- **Type:** feature
- **Priority:** 1
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Split each container stack into two services:

System service (-secrets.service):
- Runs as root for SOPS decryption
- Decrypts env files to /run/user/<uid>/secrets/
- Creates directories, fixes ownership
- Bounces user service via runuser
- Acts as restart trigger proxy (restartTriggers on compose + SOPS files)
- Includes stale health detection in ExecStartPre

User service (.service):
- Runs in user scope (rootless)
- Owns complete compose lifecycle
- Includes stale health detection in ExecStartPre (for auto-update path)
- Uses simplified cleanup script (timer cleanup only)
- restartIfChanged=false (system service triggers)
- PODMAN_SYSTEMD_UNIT points here for auto-update

Changes to mkService in stacks/lib/podman-compose.nix:
- Generate two services instead of one
- Update PODMAN_SYSTEMD_UNIT label
- Implement runuser bounce pattern (+prefix for root)
- Simplify cleanup per Appendix F

Exclude domain-monitor (defer to separate bead)

Architectural decisions from docs/podman-compose-failures.md Phase 2:
- Multi-file secrets: preserve separation
- SOPS sharing: no thundering herd (verified unique)
- Cleanup: timer cleanup only (remove redundant prune)
- Restart triggers: always rerun decrypt + bounce (simpler)

References:
- docs/podman-compose-failures.md Phase 2
- Appendix C: Cross-scope service management
- Appendix F: Cleanup script simplification

---

## nixosconfig-2qp — Stale container reuse issue with podman compose --wait

- **Status:** closed
- **Type:** bug
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

## Issue

Docker-compose with --wait flag can get stuck indefinitely waiting for containers with stale health check status. This happens when:

1. A container starts and fails its initial health check
2. The container remains in "starting" state with failed health log entry
3. Service is restarted (nixos-rebuild, manual restart, etc)
4. Docker-compose finds existing container and tries to reuse it
5. --wait blocks waiting for health check to pass
6. Container's health check system doesn't retry (only has the initial failed attempt)
7. Deployment hangs forever

## Root Cause

Docker-compose's container reuse logic + podman's health check not re-running after initial failure = deadlock situation.

## Symptoms

- Service stuck in "activating (start)" state during nixos-rebuild
- journalctl shows "Container <name> Waiting" as last message
- podman inspect shows health log with single failed entry from minutes/hours ago
- Container status shows "Up X minutes (starting)"

## Solution

Remove stale containers before redeploying:

```bash
# Find containers stuck in starting state
podman ps -a --format "table {{.Names}}\t{{.Status}}" | grep "starting"

# Check health log (should have multiple attempts, not just one old failure)
podman inspect <name> --format '{{json .State.Health.Log}}' | jq

# Remove to force fresh creation
podman rm -f <name>

# Restart service
sudo systemctl restart <stack-name>
```

## Prevention

Currently none - this is inherent to docker-compose's reuse behavior. Options:

1. Use --force-recreate flag (defeats fast restart purpose)
2. Ensure cleanup runs between deployments (unreliable)
3. Accept manual intervention when it happens (current approach)

## Status

Ongoing risk - not just migration artifact. Can happen anytime container health degrades and service restarts before cleanup.

### Notes

# Remediation Plan Approved

Based on research (nixosconfig-cm5), we have a clear solution to the stale container reuse issue.

## Root Cause (Confirmed)

Container reuse during nixos-rebuild when health checks are in bad state:
1. Container has failed/stuck health check from previous run
2. Config unchanged, so docker-compose reuses container
3. --wait blocks waiting for health to become "healthy"
4. Health check state never changes (no new checks scheduled)
5. Deployment hangs indefinitely

## Solution (Ready to Implement)

Add pre-start detection in `stacks/lib/podman-compose.nix`:

```nix
detectStaleHealth = [
  "/run/current-system/sw/bin/sh -c 'ids=$(${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format \"{{.ID}}\"); for id in $ids; do health=$(${podmanBin} inspect -f \"{{.State.Health.Status}}\" $id 2>/dev/null || echo \"none\"); if [ \"$health\" = \"starting\" ] || [ \"$health\" = \"unhealthy\" ]; then echo \"Removing container $id with stale health: $health\" >&2; ${podmanBin} rm -f $id; fi; done'"
];
```

Add to ExecStartPre (line ~217, before recreateIfLabelMismatch).

## Benefits

- Prevents indefinite hangs during rebuild
- Maintains fast reuse for healthy containers  
- Automatic remediation (no manual intervention)
- Low overhead (quick inspect check)
- Logs when containers are removed for visibility

## Testing Plan

1. Create test scenario with stuck health check
2. Verify detection removes stale container
3. Verify fresh container created successfully
4. Verify healthy containers NOT removed
5. Deploy to doc1, monitor for issues
6. Deploy to igpu during migration

## Implementation Priority

HIGH - Solves immediate production pain point (deployments hanging)

See full analysis: `docs/research/container-lifecycle-analysis.md`

---

## nixosconfig-2td — Add beads to Claude Code fleet packages

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Add pkgs.beads to homelab.claudeCode packages in claude-code.nix. Deploys bd binary to all hosts with claudeCode enabled.

---

## nixosconfig-5g2 — Re-enable vinsight-mcp package after nix-netrc deploys

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

The nix-netrc secret was updated with a classic GitHub PAT (replacing a fine-grained PAT that couldn't fetch private repo archives). The secret will deploy to all hosts via tonight's rolling update. Once deployed, uncomment pkgs.vinsight-mcp in modules/home-manager/services/claude-code.nix line 207 and commit. The next rolling update will then build with vinsight-mcp enabled. Root cause: fine-grained PATs return 404 on github.com/archive URLs (only work with api.github.com). Classic PATs work on both.

---

## nixosconfig-9sm — Add beads-mcp to .mcp.json

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Add beads-mcp server entry using uvx pattern. Provides MCP tools for structured beads access.

---

## nixosconfig-axa — Research: Container lifecycle in rebuild vs auto-update scenarios

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

## Problem Statement

Current implementation treats rebuild and auto-update the same way, but they have different requirements:

### Rebuild Time (nixos-rebuild switch)
**Goal:** Apply config changes, restart only what changed
**Current behavior:** `docker-compose up -d --wait` reuses containers if config matches
**Desired:** Incremental updates, don't restart unchanged containers
**Issue:** Stale health checks from reused containers

### Update Time (podman auto-update)
**Goal:** Pull new images, recreate all containers with latest versions
**Current behavior:** Unclear - have both system service (podman auto-update) AND user services (podman-compose@*)
**Desired:** Watchtower-style - always recreate, fresh containers
**Issue:** Dual service architecture is confusing

## Questions to Research

1. **What does podman auto-update actually do?**
   - Does it use docker-compose at all?
   - Or does it directly manage containers via podman API?
   - How does it interact with compose-managed containers?

2. **What is the dual service architecture?**
   - System service: `<stack>-stack.service` (what we interact with)
   - User service: `podman-compose@<project>.service` (for auto-update?)
   - Why both? What's the relationship?

3. **How should --wait and --force-recreate be used?**
   - Rebuild: `up -d --wait` (reuse, only restart changed)
   - Update: `up -d --wait --force-recreate` (fresh everything)
   - Or should auto-update not use compose at all?

4. **What's the right architecture?**
   - Option A: Compose for everything, different flags for rebuild vs update
   - Option B: Compose for rebuild, podman auto-update for updates (separate paths)
   - Option C: Something else entirely?

## Research Plan

1. Read `modules/nixos/homelab/containers/default.nix` auto-update implementation
2. Read `stacks/lib/podman-compose.nix` dual service setup
3. Check podman auto-update documentation
4. Trace through what actually happens during:
   - nixos-rebuild switch (which services restart, why)
   - systemctl start podman-auto-update (what gets recreated)
5. Compare to Watchtower's model for lessons learned

## Success Criteria

Clear answer to:
- When should containers be recreated vs reused?
- How should rebuild differ from update?
- Should we keep dual services or consolidate?
- What flags belong where?

## Related Issues

- nixosconfig-hbz: Stale container reuse issue

### Notes

# Research Complete - Decision Made

## Summary

Research definitively answered the open questions about rebuild vs auto-update behavior. See full analysis: `docs/research/container-lifecycle-analysis.md`

## Key Findings

1. **Container reuse DOES cause stale health checks** ✅
   - Confirmed via Docker docs, GitHub issues, community forums, and our production experience
   - When docker-compose reuses a container with stuck health state, --wait blocks indefinitely
   
2. **Dual service architecture is CORRECT** ✅
   - System service: Optimized for rebuild (smart reuse, fast incremental changes)
   - User service: Optimized for auto-update (full recreation via systemd lifecycle)
   - Each already uses the right strategy for its use case

3. **User services already recreate containers** ✅ (Key insight!)
   - Systemd runs full service cycle: ExecStop → ExecStart
   - This already provides Watchtower-style fresh deployment
   - No need for --force-recreate flag

4. **Solution: Targeted remediation, not blanket workaround** ✅
   - Add stale health detection in ExecStartPre (system service only)
   - Remove containers in "starting" or "unhealthy" state before reuse
   - Preserves fast path for healthy containers
   - Low overhead, automatic remediation

## Decision

**APPROVED:** Implement Recommendation 1 from research doc
- Add `detectStaleHealth` check to `stacks/lib/podman-compose.nix`
- Runs before `recreateIfLabelMismatch` in ExecStartPre
- Detects and removes containers with stuck health checks
- No changes to user services (already working correctly)
- Do NOT add --force-recreate (defeats incremental rebuild purpose)

## Related Work

- Update nixosconfig-hbz (stale container bug) with remediation plan
- Document health check best practices in stack templates
- Update CLAUDE.md with findings (DONE)

## Rating: 9/10

Excellent research, correct conclusions, implementation-ready recommendations.

---

## nixosconfig-k7n — Self-host MusicBrainz mirror + LRCLIB lyrics + switch Lidarr to nightly

- **Status:** closed
- **Type:** feature
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Lidarr's official metadata server (`api.lidarr.audio`) has been broken since 2025-05-21 (MusicBrainz schema change corrupted their DB, never rebuilt). LRCLIB public API is also painfully slow. Self-hosting both solves reliability AND makes everything instant.

## The Problem

### Lidarr Metadata Server
- `api.lidarr.audio` broken for 9+ months — artist searches fail, album art patchy
- Root cause: MusicBrainz schema change on 2025-05-21 corrupted the Lidarr team's database
- Workaround: `lidarr:<MBID>` prefix for searches, but the whole UI experience is degraded
- The **software** isn't broken, their **hosted instance** is. Self-hosting the same software with a fresh DB works perfectly.

### LRCLIB
- Public API at lrclib.net works but is very slow
- Tagging agent and any lyrics consumers are bottlenecked by it

## The Solution

### 1. MusicBrainz Mirror + Lidarr Metadata Server (LMD)
- **Guide**: https://github.com/blampe/hearring-aid/blob/main/docs/self-hosted-mirror-setup.md
- **6 containers**: PostgreSQL, RabbitMQ, Solr, MusicBrainz, Redis, LMD (`blampe/lidarr.metadata`)
- **Resources**: ~100GB disk, 8GB RAM (doc1 has 18GB available, needs disk expansion)
- **Replication**: Auto-replicates from upstream MusicBrainz, weekly Solr re-index cron
- **Data flow**: Lidarr → LMD (:5001) → local PostgreSQL + Solr + Fanart/Spotify/Last.fm APIs
- **API keys needed**: Fanart.tv, Spotify, Last.fm, MusicBrainz replication token from metabrainz.org
- **Community standard**: de facto solution used by multiple people, not some random project
- Also benefits: tagging agent can use local MusicBrainz API (:5000) instead of rate-limited public API

### 2. LRCLIB Self-Hosted
- **Repo**: https://github.com/tranxuanthang/lrclib
- **Stack**: Single Rust binary + SQLite — dead simple
- **Resources**: ~19GB for the database dump
- **Container**: `podman run -d -v lrclib-data:/data -p 3300:3300 lrclib-rs:latest`
- **TODO**: Investigate replication/update strategy for the lyrics database (periodic re-download of dump? incremental updates?)

### 3. Lidarr Nightly (Plugins Branch)
- Plugins branch merged into nightly as of ~Jan 2026
- Reddit: https://www.reddit.com/r/Lidarr/comments/1qglq27/the_plugin_branch_will_be_no_more/
- Image swap: `lscr.io/linuxserver/lidarr:latest` → `lscr.io/linuxserver/lidarr:nightly`
- Needed for Tubifarry plugin (can set custom metadata server endpoint)
- **ONE-WAY database migration** — take backup before switching
- Plugins are "soon" reaching master, then we can switch back

## Consumers to hook up
- **Lidarr** → point at local LMD (:5001) for metadata, via Tubifarry plugin
- **Tagging agent** (Sonnet) → point at local MusicBrainz API (:5000) for MB lookups + local LRCLIB (:3300) for lyrics
- **Any future lyrics consumers** → local LRCLIB (:3300)

## Infrastructure
- **Host**: doc1 (proxmox-vm) — 30GB RAM, 18GB available
- **Disk**: needs expansion, currently 51GB free on local disk, need ~150GB more for MB mirror + LRCLIB
- **Current Lidarr**: `lscr.io/linuxserver/lidarr:latest` in `stacks/music/docker-compose.yml`, config at `/mnt/docker/music/lidarr`
- **Music root**: `/mnt/data/Media/Music/AI/`

## Implementation order
1. Expand doc1 disk on Proxmox
2. Deploy MusicBrainz mirror (initial DB fetch ~1hr, Solr indexing ~several hrs)
3. Deploy LRCLIB (download dump, start container)
4. Switch Lidarr to nightly (backup first!)
5. Install Tubifarry, point at local LMD
6. Update tagging agent CLAUDE.md to use local endpoints
7. Verify everything works end-to-end

## References
- hearring-aid guide: https://github.com/blampe/hearring-aid/blob/main/docs/self-hosted-mirror-setup.md
- LRCLIB source: https://github.com/tranxuanthang/lrclib
- Official LidarrAPI.Metadata: https://github.com/Lidarr/LidarrAPI.Metadata
- LidMeta (lighter alternative, pre-alpha, NOT recommended): https://github.com/davedean/lidmeta
- Community pool at api.musicinfo.pro (fallback option)
- Reddit thread on plugins merge: https://www.reddit.com/r/Lidarr/comments/1qglq27/the_plugin_branch_will_be_no_more/
- GitHub issue on broken metadata: https://github.com/Lidarr/Lidarr/issues/5498

### Notes

Implementation plan written to docs/musicbrainz-mirror-plan.md. Key decision: musicbrainz-docker requires build step (Solr custom cores) so can't use our standard podman.mkService. Using thin NixOS systemd wrapper around cloned musicbrainz-docker project. Compose overrides (postgres-settings, memory-settings, volume-settings, lmd-settings) added to local/compose/ on doc1. LMD included as compose override, not separate stack. Open questions in plan doc.

---

## nixosconfig-mbc — Initialize beads on nixosconfig repo

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Run bd init, bd doctor --fix, configure sync-branch for multi-clone workflow, install git hooks.

---

## nixosconfig-n9m — Handle orphaned episodic-memory processes

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

MCP servers accumulate when sessions end abnormally (upstream #53). Need systemd user timer or cleanup script to reap orphans. May not be needed if #53 gets fixed upstream.

---

## nixosconfig-3wv — Enable bd compact (memory decay)

- **Status:** closed
- **Type:** task
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Requires Anthropic API key in sops. Summarizes closed issues to preserve decisions while freeing context. Low priority until issue volume warrants it.

---

## nixosconfig-2me — Plexamp Linux audio broken since 4.12.4 — pinned to 4.12.3

- **Status:** open
- **Type:** bug
- **Priority:** 2
- **Created:** 2026-02-24

### Description

## Problem
Plexamp 4.12.4+ on Linux has broken audio playback — seekbar advances 1 second then resets to 0, no sound output. Known upstream bug affecting all Linux distros (Debian, Fedora, Manjaro, NixOS, etc).

## Root Cause
Unknown. Plex dev (elan) acknowledged Jan 2026 saying "a fair bit of stuff changed under the hood" but no fix shipped. Affects both Flatpak and AppImage. PipeWire and PulseAudio both affected.

## Upstream Tracking
- Forum: https://forums.plex.tv/t/plexamp-flatpak-appimage-does-not-start-playback-until-audio-device-switched/929631
- GitHub: https://github.com/flathub/com.plexamp.Plexamp/issues/270

## Current Workaround
Pinned Plexamp to 4.12.3 via overlay in nix/overlay.nix. Remove the overlay when upstream ships a fix.

## Known Workarounds (others)
- Switch audio device in settings and switch back (every launch)
- --disable-background-timer-throttling flag (changes init timing, masks the bug)
- Downgrade to 4.12.3 (what we did)

## Action Items
- [ ] Monitor upstream forum thread for a fix
- [ ] When fix ships, remove the pin overlay and test

---

## nixosconfig-2r8 — Build custom arr MCP server

- **Status:** open
- **Type:** feature
- **Priority:** 2
- **Created:** 2026-02-24

### Description

The existing mcp-arr-server npm package is low quality:
- Missing @modelcontextprotocol/sdk from dependencies (packaging bug)
- No 'add artist' tool — had to fall back to raw API calls
- No 'monitor album/artist' tool
- No 'add root folder' tool
- Limited to read-only-ish operations

Build a custom MCP server for the *arr suite (starting with Lidarr) that covers the full workflow:
- Search & add artists
- List/monitor/unmonitor albums
- Trigger searches
- Manage root folders & quality profiles
- View queue & history
- Full CRUD on all Lidarr entities

Use the same pattern as our other MCP wrappers. Can expand to Sonarr/Radarr later.
Parent epic: nixosconfig-z95 (music pipeline)

### Notes

UNICODE HYPHEN BUG: Lidarr's release parser splits on ASCII hyphen (U+002D) but MusicBrainz stores artist names with non-breaking hyphen (U+2011). This means Lidarr can't match its OWN artists against NZB release names. Upstream bug, not fixable by us. Our MCP must: (1) normalize Unicode hyphens to ASCII in all comparisons, (2) match by MusicBrainz ID not parsed name when grabbing releases, (3) use ASCII names for directories. See docs/music-pipeline-postmortem.md for full context.

---

## nixosconfig-ixw — Cratedigger Xavier matching diagnosis: peer availability + track count mismatch

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

## Problem
Cratedigger repeatedly fails to download MP3 320 of xaviersobased - Xavier despite correct matches existing on soulseek.

## Root Causes Found (3 issues, all fixed)

### Issue 1: No user fallback on download failure (FIXED)
When downloads from the matched user all error out (e.g. claire419 — user is Away, transfers rejected), cratedigger gave up on the entire album. Never tried the next matching user.

### Issue 2: Search cache filetype narrowing excludes valid users (FIXED)
verify_filetype("mp3 320") requires bitRate=320 in search metadata. Many soulseek clients don't report bitrate → files cached under generic "mp3" only. Combined with cutoff_unmet logic restricting to ["mp3 320"], most valid users were invisible.

Diagnostic evidence: out of 16 search result users, only 3 had "mp3 320" in cache. The other 13 (potentially including fiqstro) were skipped because their search results lacked bitrate metadata.

### Issue 3: minimum_match_ratio=0.8 too strict (OPEN)
BonteKraai had 20 correct MP3 320 tracks but scored 0.5-0.73 due to filename format mismatch. The check_ratio truncation works for standard "01. artist - title.mp3" but not all naming conventions. Consider reducing to 0.6.

## Changes Made
File: /tmp/cratedigger/cratedigger.py (volume-mounted into cratedigger container on doc1)

1. skip_users parameter threading through try_enqueue → try_multi_enqueue → find_download
2. monitor_downloads.delete_album() tries fallback before failing (max 3 users)
3. try_enqueue/try_multi_enqueue merge file_dirs from specific AND generic base filetype
4. Diagnostic logging in check_for_match and album_match (keep for verification)

## Verification
- "Trying next user for Xavier (skipping: claire419)" confirmed in Loki logs
- Filetype broadening deployed, awaiting next run with more users in pool
- match_ratio reduction still TODO

### Notes

## Patch Plumbing

### Current patch (cutoff_unmet quality skip + user fallback + filetype broadening)
- Source: /tmp/cratedigger/cratedigger.py (git clone of mrusse/soularr + local edits)
- Deployed via: scp to doc1:/mnt/docker/music/cratedigger/cratedigger.py
- Volume mount in stacks/music/docker-compose.yml line 97:
  ${DATA_ROOT}/music/cratedigger/cratedigger.py:/app/cratedigger.py:ro
- Container restart picks up changes (no nix rebuild needed for py changes)

### Deployment workflow
1. Edit /tmp/cratedigger/cratedigger.py on WSL
2. scp to doc1:/mnt/docker/music/cratedigger/cratedigger.py
3. ssh doc1 "podman restart cratedigger" (or systemctl restart music.service)

## Implemented Fixes (2026-02-17)

### Fix 1: User fallback on download failure (DEPLOYED)
- Added skip_users parameter to try_enqueue(), try_multi_enqueue(), find_download()
- monitor_downloads.delete_album() now attempts fallback before failing:
  1. Extracts failed username from download files
  2. Adds to per-album skip_users set
  3. Clears grab_list entry, calls find_download(album, grab_list, skip_users=skip_users)
  4. If new user found: continues monitoring; if not: truly fails
  5. Max 3 user attempts cap prevents infinite loops
- Verified working: "Trying next user for Xavier (skipping: claire419)" observed in logs

### Fix 2: Search cache filetype broadening (DEPLOYED)
- ROOT CAUSE FOUND: verify_filetype("mp3 320") requires bitRate=320 in search metadata
  Many soulseek clients don't report bitrate → files cached under generic "mp3" only
- For cutoff_unmet, filetypes_to_try is restricted to ["mp3 320"] → users with generic
  "mp3" cache entries are NEVER checked, even though their files are actually 320kbps
- Fix: try_enqueue and try_multi_enqueue now merge file_dirs from both specific
  ("mp3 320") AND generic base ("mp3") before matching
- This means users like fiqstro (whose search results lack bitrate metadata) are now
  included in the matching pool

### Fix 3: Diagnostic logging (DEPLOYED, keep for now)
- check_for_match: logs track_num, dir_count, dir_filetype, dir_files per user
- album_match: logs per-track failure with best_ratio and minimum_match_ratio
- Revealed minimum_match_ratio is 0.8 — very strict for some naming conventions
  (e.g. BonteKraai had 20 correct tracks but scored 0.5-0.73)

## Open Issues

### minimum_match_ratio too strict at 0.8
- BonteKraai: 20 correct mp3 320 tracks, all scored 0.5-0.73 due to filename format
  (folder: [2026-01-30] Xavier — unusual naming convention)
- The check_ratio truncation works well for "01. artist - title.mp3" format but
  not for all naming conventions
- Consider reducing to 0.6 or 0.7

---

## nixosconfig-vn1 — Podman compose migration (4 phases)

- **Status:** open
- **Type:** epic
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Complete migration from podman-compose to podman compose with architectural improvements.

## Status

**Phase 1: Replace podman-compose with podman compose** ✅ COMPLETE (2026-02-12)
- Swapped compose tool to use podman compose (docker-compose backend)
- Added --wait flag for reliable deployments
- Implemented stale health detection (90s threshold, configurable)
- Deployed to doc1 and igpu
- All 24 stacks migrated successfully

**Phase 2: Split Services by Privilege** - NOT STARTED
- Separate SOPS decryption from compose lifecycle
- System service for secrets, user service for compose
- Core architectural change for privilege separation

**Phase 3: Simplify Auto-Update** - NOT STARTED
- Clean up auto-update wrapper
- Remove workarounds

**Phase 4: Clean Up** - NOT STARTED
- Remove version: "3.8" from compose files
- Add missing health checks
- Verify database backend

## References

- Migration plan: docs/podman-compose-failures.md
- Research: docs/research/container-lifecycle-analysis.md
- Decision: docs/decisions/2026-02-12-container-lifecycle-strategy.md

---

## nixosconfig-gu1 — Package lidarr-mcp for PyPI + MCP Registry

- **Status:** open
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Depends on lidarr-mcp generator being complete (nixosconfig-v3y). Same pattern: add lidarr_mcp/ package dir, update pyproject.toml, server.json, mcp-name tag, build + publish. Lower priority since the server isn't built yet.

---

## nixosconfig-igl — Loki \"no pfSense logs\" alert

- **Status:** open
- **Type:** task
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Belt-and-suspenders: create a Loki alert rule that fires if no logs arrive from {host=\"pfsense\"} within a 15-minute window. This catches cases where syslogd dies AND Service Watchdog fails to restart it, or if the network path to igpu:1514 breaks.\n\nDepends on the Loki alerting pipeline being set up (ruler or Grafana alerts).

---

## nixosconfig-1po — Research: podman-compose failures and migration to podman compose

- **Status:** closed
- **Type:** task
- **Priority:** 1
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

---

## nixosconfig-xnh — syslogd watchdog and restart

- **Status:** closed
- **Type:** task
- **Priority:** 1
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

syslogd on pfSense was found dead (stopped since ~Aug 2025). This meant no pfSense logs were reaching Loki despite the syslog forwarding config being correct. The Alloy syslog receiver on igpu (192.168.1.33:1514) was listening fine — syslogd just wasn't running to send anything.\n\nRoot cause: unknown — syslogd silently died and FreeBSD didn't restart it. The default rc.d start uses -s (secure/no-remote); pfSense needs its own restart method (pfSsh.php playback svc restart syslogd) which adds -c -c flags.\n\nFix applied:\n1. Restarted syslogd via pfSense service manager — logs immediately started flowing to Loki under {host=\"pfsense\"}\n2. Installed pfSense-pkg-Service_Watchdog (v1.8.7_4)\n3. Added syslogd to watchdog with notify=true — auto-restarts if it dies again

---

## nixosconfig-2ld — Configure SessionStart/PreCompact hooks

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Add bd prime (SessionStart) and bd sync (PreCompact) hooks via homelab.claudeCode.settings in base.nix. Guarded with .beads directory check.

---

## nixosconfig-8pp — Set up Seeed XIAO Smart IR Mate for Daikin AC control

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

## Seeed XIAO Smart IR Mate — Daikin AC Control

### Hardware
- **Device**: Seeed XIAO Smart IR Mate (ESP32-C3, IR TX/RX, USB-C powered)
- **AC Remote**: Daikin ARC466A40 → protocol TBD (DAIKIN 280-bit or DAIKIN312 312-bit)
- **MAC**: 3c:dc:75:bf:23:74
- **Static IP**: 192.168.1.39 (pfSense DHCP static mapping on LAN)

### ESPHome Config
- **File**: `ha/esphome/daikin-ir.yaml` (tracked in git)
- **Secrets**: `ha/esphome/secrets.yaml` (gitignored)
- **Framework**: ESP-IDF
- **GPIO3**: IR transmitter (carrier duty 50%)
- **GPIO4**: IR receiver (inverted, idle 25ms)
- **API**: No encryption
- **OTA**: Password protected

### HA Integration
- **Entity**: `climate.daikin_ir_controller_aircon` (currently non-functional)
- Added via ESPHome auto-discovery

### BLOCKER: ARC466A40 protocol unknown
- ESPHome `platform: daikin` did not work — may be wrong protocol OR was masked by RMT symbol memory bug
- Full research: `docs/daikin-arc466-esphome-research.md`
- ARC466 family spans two protocols: DAIKIN (280-bit) and DAIKIN312 (312-bit)
- A40 variant not explicitly listed for either

### Current status
- Config set to `dump: all` on IR receiver to identify protocol
- Need to flash OTA, then press physical remote at device to capture protocol ID
- If DAIKIN (280-bit): built-in `platform: daikin` should work (re-test without RMT bug)
- If DAIKIN312: need custom component via mistic100/ESPHome-IRremoteESP8266 fork

### Key Learnings
- ESP32-C3 RMT symbol memory (96 total) is shared; LED strip + IR TX + IR RX exceeds budget — removed LED
- `idle` max is 32767us with ESP-IDF RMT; Seeed reference (65500us) only works with Arduino
- NeoPixelBus is Arduino-only; use esp32_rmt_led_strip with ESP-IDF
- Flash with `sudo` needed until `dialout` group added to epimetheus (nix config change made, needs rebuild)

### Remaining
- [ ] Flash `dump: all` config and identify protocol variant
- [ ] Re-test `platform: daikin` if protocol is DAIKIN 280-bit
- [ ] Build custom component if protocol is DAIKIN312
- [ ] Update aircon automations once working
- [ ] Rebuild epimetheus for dialout group

### Notes

## IT WORKS

`platform: daikin` confirmed working with ARC466A40. The protocol was always correct — previous failure was RMT symbol memory exhaustion from the LED strip.

Tested: cool 21°C ON (beep), OFF (beep). Both responded immediately.

### Remaining
- [ ] Remove `dump: all` from receiver (noisy, not needed in production)
- [ ] Update existing aircon automations to use climate entity
- [ ] Rebuild epimetheus for dialout group
- [ ] Consider re-adding API encryption

---

## nixosconfig-dlw — DNS cache warming cron job on pfSense

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

nixos-upgrade on proxmox-vm failed because nginx couldn't resolve cache.nixos.org during config reload. Unbound's DNS cache can go cold for domains not queried frequently enough.

---

## nixosconfig-jsy — Phase 1.5: Migrate podman socket to user scope

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Move podman API service from system scope with User= to native user scope with socket activation.

## Why Migrate

Official podman docs recommend user services for rootless sockets. System services with User= have known issues:
- No session context
- Manual environment setup required
- sd_notify rejection
- Mixed system/user journal logging

## Changes Required

1. Remove system service from modules/nixos/homelab/containers/default.nix
2. Enable native user socket/service (NixOS already ships these)
3. Test socket activation and existing stack connectivity

## Low Risk

Socket path stays /run/user/1000/podman/podman.sock - no impact on existing stacks.

## Reference

docs/podman-compose-failures.md Part 5, Phase 1.5
Appendix D (socket scope research)

---

## nixosconfig-4x4 — Three-layer agentic memory system

- **Status:** closed
- **Type:** epic
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Cross-session memory system for AI agents. Four conceptual layers:

1. **Procedural (how-to)**: Patterns, runbooks, workflows, common commands. Lives in CLAUDE.md — loaded every session automatically.
2. **Declarative (facts/decisions)**: Task tracking, decision records, rationale. Lives in beads — retrieved on demand via bd prime/show.
3. **Episodic (raw history)**: Conversation archives for context recovery. Paused — episodic-memory plugin, blocked on npm dep packaging.
4. **Semantic (compressed learnings)**: LLM-distilled knowledge from closed beads and conversations. Not started — depends on episodic layer.

Phase 1 (beads as declarative memory) is live. CLAUDE.md as procedural memory predates this epic and works well. MEMORY.md is a thin bridge: critical patterns + pointers to beads.

### Notes

PAUSED — gated on credits (revisit next week). All sub-tasks consolidated here. When resuming: package episodic-memory for Nix, deploy to fleet, handle orphaned processes, track upstream fixes, enable bd compact, migrate beads overlay to flake input, then build semantic layer.

---

## nixosconfig-5p0 — Reference: Secrets Management (Sops-nix)

- **Status:** closed
- **Type:** chore
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Reference documentation for secrets management with Sops-nix.

## Secrets Management

Uses **Sops-nix** with **Age** encryption:
- Secrets encrypted against SSH host keys (converted to Age keys)
- Bootstrap paradox: Host keys decrypt master user key on boot
- Configuration: `secrets/.sops.yaml`
- When adding a new host:
  1. Get SSH host key from `/etc/ssh/ssh_host_ed25519_key.pub`
  2. Convert to Age key: `cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age`
  3. Add Age key to `secrets/.sops.yaml`
  4. Re-encrypt: `sops updatekeys --yes <file>` for each secret file

## Secrets Commands

```bash
# Edit encrypted file
sops secrets/path/to/file.env

# Add new host to secrets
cd secrets
find . -type f \( -name "*.env" -o -name "*.yaml" -o -name "ssh_key_*" \) | \
  while read file; do sops updatekeys --yes "$file"; done
```

---

## nixosconfig-b87 — Reference: VM Automation

- **Status:** closed
- **Type:** chore
- **Priority:** 4
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Reference documentation for VM automation workflow.

## VM Definitions

`vms/definitions.nix` contains:
- **imported**: Pre-existing VMs (readonly=true) - documented but not managed by automation
- **managed**: VMs provisioned and managed through automation
- **template**: Base template (VMID 9002) for cloning

## Proxmox Operations

**CRITICAL**: Always use `vms/proxmox-ops.sh` wrapper script, NEVER run Proxmox commands directly via SSH.

The wrapper protects production VMs (104, 109, 110) from accidental modification by checking the readonly flag before ANY destructive operation.

## Provisioning Workflow

1. Define VM in `vms/definitions.nix` under `managed`
2. Create host configuration in `hosts/{name}/`:
   - `configuration.nix` (NixOS config)
   - `disko.nix` (disk partitioning)
   - `hardware-configuration.nix` (hardware detection)
   - `home.nix` (Home Manager config)
3. Add placeholder entry to `hosts.nix` with temporary publicKey (default temp password hash: `temp123`)
4. Run: `nix run .#provision-vm <vm-name>`
5. After provisioning, run: `nix run .#post-provision-vm <vm-name> <IP> <VMID>`
6. Deploy with secrets: `nixos-rebuild switch --flake .#<vm-name> --target-host <vm-name>`

Post-provision expects SOPS identity; it mirrors the `dc` lookup order (env vars, age key files, host key, user key).

## VM Operations Commands

```bash
# List all VMs
./vms/proxmox-ops.sh list

# Get VM status
./vms/proxmox-ops.sh status <vmid>

# Start/stop VM (protected - checks readonly flag)
./vms/proxmox-ops.sh start <vmid>
./vms/proxmox-ops.sh stop <vmid>

# Provision new VM
nix run .#provision-vm <vm-name>

# Post-provision (fleet integration)
nix run .#post-provision-vm <vm-name> <IP> <VMID>

# Get next available VMID
./vms/proxmox-ops.sh next-vmid
```

---

## nixosconfig-1me — Test MCP integration and end-to-end pipeline

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Phase 4+5: MCP servers working and full pipeline validated.

- Fill real credentials in sops secrets
- Restart Claude Code to pick up MCP servers
- Test Lidarr MCP: search for an artist
- Test Soulseek MCP: search for an album
- End-to-end: "get me [album]" → search → download → import → Plex
- Add Plex library path for /mnt/data/music/ai if not present
- Optional: Gotify notification on download complete
- Update CLAUDE.md with music automation workflow

---

## nixosconfig-aw3 — Fresh Lidarr setup and cratedigger bridge configuration

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Phase 2+3: Configure Lidarr and wire up cratedigger.

- Fresh Lidarr config at http://doc1:8686
- Set root folder to /mnt/data/music/ai
- Configure import settings (tagging, naming)
- Grab API key from Settings → General
- Update secrets/arr-mcp.env with Lidarr API key
- Copy cratedigger config to doc1 with Lidarr API key
- Test: add album to Lidarr wanted list, verify cratedigger picks it up

---

## nixosconfig-f57 — Migrate to official programs.claude-code HM module + add plugin support

- **Status:** open
- **Type:** feature
- **Priority:** 2
- **Created:** 2026-02-24

### Description

DISCOVERY: Official Home Manager module exists at nix-community/home-manager/modules/programs/claude-code.nix with proper options-based config BUT no plugin support.

CURRENT STATE:
We maintain homelab.claudeCode custom module with:
- Plugin installation/management
- Node.js bundling and PATH setup
- Writable cache directory for npm install
- Native module symlink patching

OFFICIAL MODULE PROVIDES:
- programs.claude-code.settings (JSON schema validated)
- programs.claude-code.{agents,commands,hooks,skills,rules}
- programs.claude-code.mcpServers (MCP integration)
- Proper option system with validation
- Maintained by nix-community

MIGRATION PLAN:
1. Switch base from homelab.claudeCode to programs.claude-code
2. Move settings/hooks/skills to official options
3. Extend with programs.claude-code.plugins option for:
   - Plugin source/version declaration
   - Writable cache management
   - Node.js dependency handling
   - Native module compilation
4. Keep plugin extension local OR upstream to home-manager

DECISION POINT:
- Local extension: Faster, keeps plugin complexity out of HM
- Upstream PR: Proper solution, benefits community, slower

REFERENCES:
- Official module: https://github.com/nix-community/home-manager/blob/master/modules/programs/claude-code.nix
- Maintainer: lib.maintainers.khaneliman
- Related: sadjow/claude-code-nix, MachsteNix/claude-code-nix

BLOCKS:
- Full episodic-memory integration (nixosconfig-0sb)
- Clean MCP server deployment (nixosconfig-4ts)

---

## nixosconfig-3zg — Music Automation: Soulseek → Lidarr → Plex pipeline

- **Status:** in_progress
- **Type:** epic
- **Priority:** 2
- **Created:** 2026-02-24

### Description

Enable Claude Code to fulfill requests like "get me this album" by searching Soulseek, downloading via slskd, tagging via Lidarr, and serving via Plex.

Architecture: Option C (Hybrid) — Cratedigger daemon for bulk/background, direct MCP for immediate requests.
Host: doc1 (proxmox-vm). Music library: /mnt/data/music/ai.
Quality default: 320kbps MP3 (overridable per request).

Full plan originally in docs/music-automation-plan.md (moved here).

### Notes

# Music Automation Plan: Soulseek → Lidarr → Plex Pipeline

**Goal**: Enable Claude Code to fulfill requests like "get me this album" by searching Soulseek, downloading, tagging, and making available in Plex.

**Date**: 2026-02-05
**Status**: Infrastructure code complete, manual setup remaining

---

## Decisions Made

| Question | Decision |
|----------|----------|
| **Host for slskd** | doc1 (main services VM) |
| **Host for Lidarr** | doc1 (already deployed, unused) |
| **Lidarr state** | Fresh start — nuke existing config |
| **Music library path** | `/mnt/data/music/ai` (new subfolder for AI-sourced) |
| **Soulseek credentials** | Existing account, store in sops |
| **Secrets storage** | sops-encrypted (consistent with repo pattern) |
| **Architecture** | Option C: Hybrid (Cratedigger daemon + direct MCP for immediate) |
| **Default quality** | 320kbps MP3 (overridable per request) |
| **Duplicate handling** | Skip and warn if exists in library |
| **Plex scanning** | Auto-scan enabled (no action needed) |
| **Notifications** | Gotify on download complete |
| **slskd MCP approach** | Try existing SoulseekMCP, generate from OpenAPI if gaps |
| **MCP server location** | Local (current pattern) |

---

## Proposed Architecture

```
User: "Get me Whiskeytown - Strangers Almanac"
                    │
                    ▼
            ┌───────────────┐
            │  Claude Code  │
            └───────┬───────┘
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   SoulseekMCP   Lidarr MCP   Plex MCP
        │           │           │
        ▼           ▼           ▼
      slskd      Lidarr       Plex
        │           │           │
        └─────┬─────┘           │
              ▼                 │
        Download Folder         │
              │                 │
              └────► Lidarr ────┘
                   (import/tag)
                        │
                        ▼
                  Music Library
                        │
                        ▼
                      Plex
```

### Option A: Full MCP Control (Maximum Flexibility)

Claude controls each step directly via MCP servers:
1. Search Soulseek via SoulseekMCP
2. Download via SoulseekMCP
3. Trigger Lidarr import via Lidarr MCP
4. Trigger Plex scan via Plex MCP

**Pros**: Full control, can handle edge cases, immediate feedback
**Cons**: More MCP servers to maintain, Claude orchestrates everything

### Option B: Cratedigger Daemon (Most Hands-Off)

Claude only adds to Lidarr's wanted list; Cratedigger daemon handles the rest:
1. Add album to Lidarr wanted list via Lidarr MCP
2. Cratedigger (daemon) monitors wanted list every 5 min
3. Cratedigger searches slskd and triggers download
4. Lidarr auto-imports from download folder
5. Plex auto-scans library

**Pros**: Simple, robust, handles retries/failures
**Cons**: Not immediate (5 min polling), less visibility

### Option C: Hybrid

Claude can do both — use Cratedigger for bulk/background, direct MCP for immediate requests.

---

## Components Required

### New Docker Services

| Service | Image | Purpose | Port |
|---------|-------|---------|------|
| slskd | `slskd/slskd` | Soulseek client with REST API | 5030 (web), 5031 (API) |
| cratedigger | `mrusse/soularr` | Lidarr ↔ slskd bridge | None (daemon) |

### Existing Services to Configure

| Service | Current State | Changes Needed |
|---------|---------------|----------------|
| Lidarr | Deployed on doc1, unused | Fresh config: root folder `/mnt/data/music/ai`, Cratedigger as download bridge |
| Plex | Working, auto-scan enabled | Add `/mnt/data/music/ai` to music library |

### MCP Servers to Add

| MCP Server | Source | Purpose |
|------------|--------|---------|
| SoulseekMCP | `@jotraynor/SoulseekMCP` | Direct Soulseek search/download |
| mcp-arr-server | `npm: mcp-arr-server` | Lidarr management |
| plex-mcp-server | `npm: plex-mcp` | Plex library scan/search |

---

## Implementation Status

### Completed (2026-02-05)

| Item | File | Notes |
|------|------|-------|
| Docker compose for slskd | `stacks/music/docker-compose.yml` | Added slskd service with volumes, ports 5030/5031 |
| Docker compose for cratedigger | `stacks/music/docker-compose.yml` | Daemon that bridges Lidarr wanted list → slskd |
| Firewall ports | `stacks/music/docker-compose.nix` | Added 5030, 5031 to firewallPorts |
| MCP wrapper: arr | `scripts/mcp-arr.sh` | Sources secrets, runs `npx -y mcp-arr-server` |
| MCP wrapper: soulseek | `scripts/mcp-soulseek.sh` | Sources secrets, runs soulseek MCP |
| MCP config | `.mcp.json` | Added `arr` and `soulseek` entries |
| NixOS MCP module | `modules/nixos/services/mcp.nix` | Added arr/soulseek options with sops integration |
| Secrets: arr-mcp.env | `secrets/arr-mcp.env` | sops-encrypted, has placeholder API key |
| Secrets: soulseek-mcp.env | `secrets/soulseek-mcp.env` | sops-encrypted, has placeholder credentials |
| Secrets: music.env | `secrets/music.env` | Updated with SOULSEEK_USERNAME/PASSWORD placeholders |
| Cratedigger config template | `stacks/music/cratedigger/config.yaml` | Template config, needs Lidarr API key |
| Quality gate | - | `check` passes |

**Note**: The MCP module is defined but NOT enabled in any host config yet. Nothing will run until you explicitly enable it.

### Remaining Manual Steps

```bash
# 1. Fill in your real Soulseek credentials
sops secrets/soulseek-mcp.env
# Change:
#   SOULSEEK_USERNAME=your_actual_username
#   SOULSEEK_PASSWORD=your_actual_password

sops secrets/music.env
# Change the SOULSEEK_USERNAME and SOULSEEK_PASSWORD lines

# 2. Enable the MCP module in proxmox-vm host config
#    Edit hosts/proxmox-vm/configuration.nix and add:
#
#    homelab.mcp = {
#      enable = true;
#      arr.enable = true;
#      soulseek.enable = true;
#    };

# 3. Create the AI music directory on doc1
ssh proxmox-vm 'mkdir -p /mnt/data/music/ai'

# 4. Deploy to doc1
nixos-rebuild switch --flake .#proxmox-vm --target-host proxmox-vm

# 5. Fresh Lidarr setup
#    - Browse to http://doc1:8686
#    - Complete initial setup wizard
#    - Settings → Media Management → Root Folder: /mnt/data/music/ai
#    - Settings → General → Copy the API Key

# 6. Update arr secrets with Lidarr API key
sops secrets/arr-mcp.env
# Change LIDARR_API_KEY to the key from Lidarr

# 7. Copy cratedigger config to doc1 and update it
scp stacks/music/cratedigger/config.yaml proxmox-vm:/mnt/data/music/cratedigger/
ssh proxmox-vm 'nano /mnt/data/music/cratedigger/config.yaml'
# Update the lidarr.api_key field with your Lidarr API key

# 8. Restart the music stack on doc1
ssh proxmox-vm 'systemctl --user restart podman-compose@music'

# 9. Verify services are running
ssh proxmox-vm 'podman ps | grep -E "slskd|cratedigger|lidarr"'

# 10. Test slskd web UI
#     Browse to http://doc1:5030
#     Should show slskd interface, check Settings for Soulseek connection status

# 11. Add Plex library (if not already done)
#     In Plex, add /mnt/data/music/ai as a Music library source
```

### Testing the Pipeline

Once setup is complete:

1. **Test Lidarr MCP**: Restart Claude Code, then ask "search for artist Lucinda Williams in Lidarr"
2. **Test slskd connection**: Check http://doc1:5030 shows "Connected" to Soulseek
3. **Test Cratedigger**: Add an album to Lidarr's wanted list, wait 5 min, check if Cratedigger triggers a search
4. **End-to-end**: Ask Claude "get me Whiskeytown Strangers Almanac" and watch it flow through

---

## Open Items

### Still To Determine

- [x] Exact path for music library: `/mnt/data/music/ai`
- [ ] Lidarr API key (will get after fresh config)
- [ ] Plex token (for MCP server if needed — may not be required if auto-scan works)
- [ ] Network: verify slskd can reach Soulseek network from doc1
- [x] Lidarr naming format preference: use defaults

### Notes

- Lidarr wasn't actually flakey — just never properly configured
- Music Assistant should automatically see new files via Plex (auto-scan enabled)
- Quality is overridable per request, 320kbps default

---

## Implementation Phases

### Phase 1: Infrastructure [CODE COMPLETE]
- [x] Docker compose for slskd
- [x] Docker compose for cratedigger
- [x] Firewall ports configured
- [ ] Deploy to doc1
- [ ] Configure Soulseek credentials (fill in sops placeholders)
- [ ] Test slskd web UI and API manually
- [ ] Verify network connectivity (Soulseek servers reachable)

### Phase 2: Lidarr Setup [PENDING]
- [ ] Fresh Lidarr configuration (nuke existing)
- [ ] Set root folder to `/mnt/data/music/ai`
- [ ] Configure import settings (tagging, naming)
- [ ] Get API key from Settings → General
- [ ] Test manual import of a downloaded album

### Phase 3: Bridge Setup [CODE COMPLETE]
- [x] Cratedigger container added to docker-compose
- [x] Cratedigger config template created
- [ ] Copy config to doc1 and add Lidarr API key
- [ ] Test: add album to Lidarr, verify Cratedigger picks it up

### Phase 4: MCP Integration [CODE COMPLETE]
- [x] Add mcp-arr-server to .mcp.json
- [x] Add Soulseek MCP to .mcp.json
- [x] MCP wrapper scripts created
- [x] NixOS module extended for arr/soulseek secrets
- [x] Sops secrets created (with placeholders)
- [ ] Fill in real credentials
- [ ] Test from Claude Code: search, download, import flow

### Phase 5: Polish [PENDING]
- [ ] Update CLAUDE.md with music automation workflow
- [ ] Add Plex library path if not present
- [ ] Optional: Gotify notifications on download complete
- [ ] Optional: Quality filters in Cratedigger/slskd config

---

## Example MCP Configuration

```json
{
  "mcpServers": {
    "arr": {
      "command": "npx",
      "args": ["-y", "mcp-arr-server"],
      "env": {
        "LIDARR_URL": "http://lidarr.local:8686",
        "LIDARR_API_KEY": "${LIDARR_API_KEY}"
      }
    },
    "soulseek": {
      "command": "node",
      "args": ["/path/to/SoulseekMCP/dist/index.js"],
      "env": {
        "SOULSEEK_USERNAME": "${SOULSEEK_USER}",
        "SOULSEEK_PASSWORD": "${SOULSEEK_PASS}",
        "DOWNLOAD_PATH": "/downloads/music"
      }
    },
    "plex": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-plex"],
      "env": {
        "PLEX_URL": "http://plex.local:32400",
        "PLEX_TOKEN": "${PLEX_TOKEN}"
      }
    }
  }
}
```

---

## Example Docker Compose Additions

```yaml
services:
  slskd:
    image: slskd/slskd:latest
    container_name: slskd
    environment:
      - SLSKD_REMOTE_CONFIGURATION=true
      - SLSKD_SHARED_DIR=/music
      - SLSKD_DOWNLOADS_DIR=/downloads
    volumes:
      - ./slskd/config:/app
      - /path/to/music:/music:ro      # Share with Soulseek network
      - /path/to/downloads:/downloads  # Download location
    ports:
      - "5030:5030"  # Web UI
      - "5031:5031"  # API
    restart: unless-stopped

  cratedigger:
    image: mrusse/soularr:latest
    container_name: cratedigger
    environment:
      - ANTHROPIC_API_KEY=not_needed   # Only if using AI features
    volumes:
      - ./cratedigger/config:/config
    depends_on:
      - slskd
    restart: unless-stopped
```

---

## Risk Considerations

1. **Soulseek availability**: Files may not be available, need graceful handling
2. **Quality inconsistency**: Different uploaders = different quality/tagging
3. **Legal considerations**: Soulseek operates in a gray area depending on jurisdiction
4. **Network stability**: Soulseek peers can disconnect mid-download
5. **Storage**: Music libraries grow; plan for capacity

---

## Next Steps

1. **Fill in Soulseek credentials** in `secrets/soulseek-mcp.env` and `secrets/music.env`
2. **Enable MCP module** in `hosts/proxmox-vm/configuration.nix` (see Remaining Manual Steps)
3. **Deploy to doc1**: `nixos-rebuild switch --flake .#proxmox-vm --target-host proxmox-vm`
4. **Fresh Lidarr setup** at http://doc1:8686, get API key
5. **Update Lidarr API key** in `secrets/arr-mcp.env` and cratedigger config on doc1
6. **Test the pipeline** end-to-end

---

## References

- [slskd GitHub](https://github.com/slskd/slskd)
- [slskd API Docs](https://github.com/slskd/slskd/blob/master/docs/api.md)
- [Cratedigger](https://cratedigger.net)
- [Cratedigger GitHub](https://github.com/mrusse/soularr)
- [SoulseekMCP](https://glama.ai/mcp/servers/@jotraynor/SoulseekMCP)
- [mcp-arr-server](https://www.npmjs.com/package/mcp-arr-server)
- [Lidarr](https://lidarr.audio/)
- [Lidarr API](https://lidarr.audio/docs/api/)

---

## nixosconfig-2kc — Package bd binary in NixOS overlay

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

fetchurl pre-built binary from GitHub Releases into nix/overlay.nix. Temporary until upstream flake builds (Go >= 1.25.6 blocker).

---

## nixosconfig-7ef — Review music plan, existing code, and infra state

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Before any deployment, review the full plan together:

1. Audit existing code:
   - stacks/music/docker-compose.yml (slskd + cratedigger services)
   - stacks/music/docker-compose.nix (firewall ports, nix integration)
   - stacks/music/cratedigger/config.yaml (template config)
   - scripts/mcp-arr.sh, scripts/mcp-soulseek.sh (MCP wrappers)
   - modules/nixos/services/mcp.nix (arr/soulseek options)
   - .mcp.json entries for arr + soulseek

2. Check infra state on doc1:
   - Is Lidarr already running? What state is it in?
   - Does /mnt/data/music/ exist? What's in it?
   - Are slskd/cratedigger containers deployed or just defined?
   - Network: can doc1 reach Soulseek network?

3. Validate decisions still make sense:
   - Option C (hybrid) still the right call?
   - MCP server choices still current/maintained?
   - Any new alternatives since Feb 5?

4. Discuss and confirm the deployment order before proceeding.

---

## nixosconfig-k4e — Deploy slskd + cratedigger to doc1 and fill sops credentials

- **Status:** closed
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24
- **Closed:** 2026-02-24

### Description

Phase 1: Get the infrastructure running on doc1.

- Fill real Soulseek credentials in secrets/soulseek-mcp.env and secrets/music.env
- Enable homelab.mcp module in hosts/proxmox-vm/configuration.nix
- Create /mnt/data/music/ai on doc1
- Deploy: nixos-rebuild switch --flake .#proxmox-vm --target-host proxmox-vm
- Verify slskd web UI at http://doc1:5030
- Verify Soulseek network connectivity

---

## nixosconfig-5xm — Beads Dolt migration: connect remaining hosts to centralised doc1 server

- **Status:** open
- **Type:** task
- **Priority:** 2
- **Created:** 2026-02-24

### Description

All hosts need to run bd init pointing at doc1's centralised Dolt server (100.89.160.60:3307). doc1 is the server (doltServer = true), all others are remote clients. Setup instructions are in modules/home-manager/services/claude-code.nix and CLAUDE.md.

### Design

## Architecture

doc1 runs the single Dolt SQL server. All other hosts connect over Tailscale.
Auth: user beads / password beads (BEADS_DOLT_PASSWORD env var set by module).

## Per-Host Setup

After nixos-rebuild switch or home-manager switch:

```bash
cd ~/nixosconfig

# Point at doc1's Dolt server (on doc1 itself, use --server-host 127.0.0.1)
bd init --prefix nixosconfig \
  --server-host 100.89.160.60 \
  --server-port 3307 \
  --server-user beads

bd hooks install --force
bd config set beads.role maintainer

# Verify
bd stats
bd ready
```

If bd stats shows 0 issues, hydrate from JSONL:
```bash
bd init --prefix nixosconfig --from-jsonl --force
```

## Host Status
- proxmox-vm (doc1) — server, DONE
- epimetheus — pending
- framework — pending
- wsl — pending
- dev — pending
- igpu — pending
- caddy — pending

## Notes
- Old .beads/beads.db SQLite files can be deleted
- JSONL is still git-tracked via hooks (pre-commit exports, post-merge imports)
- The old beads-sync branch is obsolete
- Full docs in modules/home-manager/services/claude-code.nix

---

## nixosconfig-ccc — podman API service leaves orphaned rootlessport processes during nixos-upgrade, causing podman to hang

- **Status:** open
- **Type:** bug
- **Priority:** 1
- **Created:** 2026-02-24

### Description

During nixos-upgrade on igpu (2026-02-25), the systemd reload stopped podman.service cleanly but left 4 orphaned rootlessport/exe processes. When podman.socket restarted, these stale network processes caused all subsequent podman commands (podman ps etc) to hang indefinitely. This in turn caused the detect-stale-health and recreate-if-label-mismatch ExecStartPre scripts for loki-stack and jellyfin-stack to time out, which cascaded into home-manager-abl030.service timing out (5min), and nixos-upgrade reporting failure (exit code 4). The actual NixOS switch succeeded - only the HM restart was broken. Fix: add ExecStopPost to podman.service to kill orphaned rootlessport processes on stop. e.g. ExecStopPost=pkill -u abl030 rootlessport || true

### Notes

Prior podman research (nixosconfig-axa, nixosconfig-3re) focused on stale container health checks hanging docker-compose --wait. This is a different layer: the podman API service itself dies uncleanly during nixos-upgrade systemd reload, leaving orphaned rootlessport/exe processes that cause the restarted socket to hang. Not previously encountered or documented.

---

## nixosconfig-430 — Remove stale dolt-server.service from non-doc1 hosts and run bd init pointing at doc1

- **Status:** open
- **Type:** chore
- **Priority:** 2
- **Created:** 2026-02-24

### Description

igpu had a stale dolt-server.service unit from the old per-host Dolt era still running, causing bd init to silently connect to the empty local DB instead of doc1. Fixed on igpu by stopping/disabling the unit. The same issue likely affects framework, wsl, epimetheus, dev. Each needs: (1) systemctl --user stop/disable dolt-server.service && rm ~/.config/systemd/user/dolt-server.service, (2) rm -rf nixosconfig/.beads && bd init --prefix nixosconfig --server-host 100.89.160.60 --server-port 3307 --server-user beads, (3) bd hooks install --force && bd config set beads.role maintainer

---

## nixosconfig-id0 — Beads skip-worktree on issues.jsonl blocks git rebase/merge

- **Status:** open
- **Type:** bug
- **Priority:** 3
- **Created:** 2026-02-24

### Description

Beads hooks set skip-worktree flag on .beads/issues.jsonl. This hides local changes from git status but causes git rebase/merge to fail with 'local changes would be overwritten' even though status shows clean. Workaround: git update-index --no-skip-worktree .beads/issues.jsonl before rebase. May need to report upstream or add a pre-rebase hook to clear it.

---

