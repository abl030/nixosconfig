# Testing: podman-compose --force-recreate Necessity

## Background

We added `--force-recreate` to all podman-compose stack restarts to prevent old containers from accumulating when `podman-compose down` fails or doesn't complete cleanly.

**Side effect:** Every restart creates new container IDs, which causes Dozzle to accumulate "ghost" entries of old containers in the UI. We worked around this by adding daily 3am restarts of both management stacks.

**Question:** Do we still need `--force-recreate`, or can we remove it and rely on normal podman-compose behavior?

## Test Objective

Determine if removing `--force-recreate` from ExecStart and ExecReload causes old containers to accumulate.

## Test Environment

- **Host:** igpu (192.168.1.33)
- **Test Stack:** Simple alpine container (`stacks/test-force-recreate/docker-compose.yml`)
- **Current State:** Using `--force-recreate` in both ExecStart and ExecReload for production stacks

## Prerequisites

### Test Compose File

A minimal test stack at `stacks/test-force-recreate/docker-compose.yml`:
```yaml
version: "3.8"
services:
  test-container:
    container_name: test-force-recreate
    image: docker.io/alpine:latest
    command: sleep infinity
    restart: unless-stopped
```

No NixOS integration needed - we'll use `podman-compose` directly for faster testing.

## Testing Methodology

### How to Count Containers

Use podman to count test containers (ground truth, independent of Dozzle):

```bash
# Count ALL test containers (running + exited)
podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}} {{.Names}} {{.Status}}" | wc -l

# List them with details
podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Created}}"

# Count only running
podman ps --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l

# Count only exited/stopped
podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --filter "status=exited" --format "{{.ID}}" | wc -l
```

### How to Check Dozzle for Ghost Containers

Dozzle logs errors when it tries to access containers that no longer exist. Check the main dozzle server logs on doc1:

```bash
# Count ghost container errors in Dozzle logs
ssh doc1 'docker logs management-dozzle-1 2>&1' | grep "no container with name or ID" | grep -o '"container":"[^"]*"' | sort -u | wc -l

# List the ghost container IDs
ssh doc1 'docker logs management-dozzle-1 2>&1' | grep "no container with name or ID" | grep -o '"container":"[^"]*"' | sort -u

# Get recent ghost errors (last 50 log lines)
ssh doc1 'docker logs --tail 50 management-dozzle-1 2>&1' | grep "no container with name or ID"
```

This is the **definitive test** - if Dozzle is tracking ghost containers, you'll see these errors.

## Test Procedure

### Baseline Test (WITH --force-recreate)

1. **Clean slate:**
   ```bash
   cd /home/abl030/nixosconfig/stacks/test-force-recreate
   podman-compose down
   podman container prune -f --filter "label=io.podman.compose.project=test-force-recreate"
   ```

2. **Start fresh:**
   ```bash
   podman-compose up -d --force-recreate --remove-orphans
   sleep 3
   ```

3. **Record baseline container count:**
   ```bash
   BASELINE=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
   echo "Baseline: $BASELINE containers"
   ```

4. **Perform 5 recreate cycles:**
   ```bash
   for i in {1..5}; do
     echo "=== Recreate cycle $i ==="
     podman-compose up -d --force-recreate --remove-orphans
     sleep 3
     COUNT=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
     RUNNING=$(podman ps --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
     EXITED=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --filter "status=exited" --format "{{.ID}}" | wc -l)
     echo "After cycle $i: Total=$COUNT (Running=$RUNNING, Exited=$EXITED)"
   done
   ```

5. **Check Dozzle for ghosts:**
   ```bash
   ssh doc1 'docker logs --tail 100 management-dozzle-1 2>&1' | grep "no container with name or ID" | tail -10
   ```

6. **Expected result:** Container count increases by 1 per cycle (new container created, old one left behind as exited), and Dozzle logs show increasing ghost container errors

### Test 1: WITHOUT --force-recreate

**Hypothesis:** Normal `up -d` without force-recreate should reuse containers if nothing changed.

1. **Clean slate:**
   ```bash
   cd /home/abl030/nixosconfig/stacks/test-force-recreate
   podman-compose down
   podman container prune -f --filter "label=io.podman.compose.project=test-force-recreate"
   ```

2. **Start fresh:**
   ```bash
   podman-compose up -d --remove-orphans
   sleep 3
   BASELINE=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
   echo "Baseline: $BASELINE containers"
   ```

3. **Perform 5 up cycles (WITHOUT --force-recreate):**
   ```bash
   for i in {1..5}; do
     echo "=== Up cycle $i ==="
     podman-compose up -d --remove-orphans
     sleep 3
     COUNT=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
     RUNNING=$(podman ps --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
     EXITED=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --filter "status=exited" --format "{{.ID}}" | wc -l)
     echo "After cycle $i: Total=$COUNT (Running=$RUNNING, Exited=$EXITED)"
   done
   ```

4. **Check Dozzle for ghosts:**
   ```bash
   ssh doc1 'docker logs --tail 100 management-dozzle-1 2>&1' | grep "no container with name or ID" | tail -10
   ```

5. **Success criteria:**
   - Total container count stays at baseline (1 container)
   - No accumulation of exited containers
   - Container IDs remain stable across cycles
   - **No new ghost container errors in Dozzle logs**

### Test 2: Simulating Failed Down

**Hypothesis:** The original issue was `podman-compose down` failing. Test if `up -d` without --force-recreate handles this.

1. **Clean slate:**
   ```bash
   cd /home/abl030/nixosconfig/stacks/test-force-recreate
   podman-compose down
   podman container prune -f --filter "label=io.podman.compose.project=test-force-recreate"
   ```

2. **Simulate down failures:**
   ```bash
   for i in {1..3}; do
     echo "=== Simulated failure cycle $i ==="

     # Start normally
     podman-compose up -d --remove-orphans
     sleep 2

     # Kill podman-compose mid-down to simulate failure
     podman-compose down &
     sleep 0.5
     pkill -9 podman-compose || true
     sleep 1

     # Try up again - do containers accumulate?
     podman-compose up -d --remove-orphans
     sleep 2

     COUNT=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
     RUNNING=$(podman ps --filter "label=io.podman.compose.project=test-force-recreate" --format "{{.ID}}" | wc -l)
     EXITED=$(podman ps -a --filter "label=io.podman.compose.project=test-force-recreate" --filter "status=exited" --format "{{.ID}}" | wc -l)
     echo "After simulated failure $i: Total=$COUNT (Running=$RUNNING, Exited=$EXITED)"
   done
   ```

3. **Success criteria:**
   - No accumulation despite failed down commands
   - Container count stays at 1
   - **If containers accumulate, this proves we need --force-recreate**

## Expected Results

### Scenario A: --force-recreate IS needed
- Test 1 or Test 2 shows container accumulation
- Containers with "Exited" status pile up
- Total count grows with each restart/reload
- **Action:** Keep --force-recreate, accept daily dozzle restarts

### Scenario B: --force-recreate NOT needed
- Test 1 and Test 2 show stable container counts
- No accumulation of exited containers
- Container IDs remain stable when config unchanged
- **Action:** Remove --force-recreate, remove daily dozzle restarts, enjoy stable Dozzle UI

### Scenario C: Only ExecStart needs it
- Test 1 passes (reload works without it)
- Test 2 fails (restart accumulates containers)
- **Action:** Keep --force-recreate only in ExecStart, reduce dozzle ghost frequency

## Success Metrics

For each test, record:
1. **Starting container count** (after clean start)
2. **Ending container count** (after 5 cycles)
3. **Number of exited containers** at end
4. **Container ID stability** (did IDs change unnecessarily?)
5. **Dozzle ghost count** (from error logs)

A "successful" removal of --force-recreate means:
- Container count increase ≤ 1 per cycle (acceptable tolerance)
- Exited containers ≤ 2 total at end
- No unbounded growth pattern
- **Dozzle ghost container errors remain at 0 or don't increase**

## Rollback Procedure

If tests show --force-recreate is still needed:

```bash
# Revert changes in git
git checkout stacks/lib/podman-compose.nix

# Rebuild
nixos-rebuild switch --flake .#igpu

# Confirm daily restart timers are active
systemctl list-timers | grep management-stack-daily-restart
```

## Notes

- All tests should be run on igpu (where podman rootless is active)
- Tests should be performed during low-usage time to avoid service disruption
- Monitor Jellyfin service health during tests
- The jellyfin compose project has ~6-7 containers typically (jellyfin, jellystat, postgres, caddy, tailscale, inotify-bridge, watchstate)
