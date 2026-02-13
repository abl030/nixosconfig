# Decision: Container Lifecycle Strategy for Rebuild vs Auto-Update

**Date:** 2026-02-12
**Status:** Implemented and evolved (Phase 1 + Phase 2 complete)
**Related Beads:** nixosconfig-cm5 (research), nixosconfig-hbz (bug fix)
**Research Document:** [docs/research/container-lifecycle-analysis.md](../research/container-lifecycle-analysis.md)
**Implementation:** [stacks/lib/podman-compose.nix](../../stacks/lib/podman-compose.nix)

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

Decision update:
- The earlier "dual service architecture is required" conclusion is superseded by the Phase 2 design.
- Current design keeps hard-fail invariant enforcement while reducing orchestration coupling.

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

- Full research: [docs/research/container-lifecycle-analysis.md](../research/container-lifecycle-analysis.md)
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
