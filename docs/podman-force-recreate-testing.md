# Testing: podman-compose --force-recreate Necessity

## Background

We added `--force-recreate` to all podman-compose stack restarts to prevent old containers from accumulating when `podman-compose down` fails or doesn't complete cleanly.

**Side effect:** Every restart creates new container IDs, which causes Dozzle to accumulate "ghost" entries of old containers in the UI. We worked around this by adding daily 3am restarts of both management stacks.

**Question:** Do we still need `--force-recreate`, or can we remove it and rely on normal podman-compose behavior?

## Test Objective

Determine if removing `--force-recreate` from ExecStart and ExecReload causes old containers to accumulate.

## Test Environment

- **Host:** igpu (192.168.1.33)
- **Test Stack:** jellyfin-stack
- **Current State:** Using `--force-recreate` in both ExecStart and ExecReload

## Prerequisites

### Required Permissions

Claude needs passwordless sudo for these specific commands on igpu:
```bash
/run/current-system/sw/bin/systemctl restart jellyfin-stack.service
/run/current-system/sw/bin/systemctl reload jellyfin-stack.service
/run/current-system/sw/bin/systemctl stop jellyfin-stack.service
/run/current-system/sw/bin/systemctl start jellyfin-stack.service
```

Add to sudoers (if not already present):
```
abl030 ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl restart jellyfin-stack.service
abl030 ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl reload jellyfin-stack.service
abl030 ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl stop jellyfin-stack.service
abl030 ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl start jellyfin-stack.service
```

## Testing Methodology

### How to Count Containers

Use podman to count jellyfin-related containers (ground truth, independent of Dozzle):

```bash
# Count ALL jellyfin containers (running + exited)
podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}} {{.Names}} {{.Status}}" | wc -l

# List them with details
podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Created}}"

# Count only running
podman ps --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l

# Count only exited/stopped
podman ps -a --filter "label=io.podman.compose.project=jellyfin" --filter "status=exited" --format "{{.ID}}" | wc -l
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
   sudo systemctl stop jellyfin-stack.service
   podman container prune -f --filter "label=io.podman.compose.project=jellyfin"
   ```

2. **Start fresh:**
   ```bash
   sudo systemctl start jellyfin-stack.service
   sleep 10
   ```

3. **Record baseline container count:**
   ```bash
   BASELINE=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
   echo "Baseline: $BASELINE containers"
   ```

4. **Perform 5 reload cycles:**
   ```bash
   for i in {1..5}; do
     echo "=== Reload cycle $i ==="
     sudo systemctl reload jellyfin-stack.service
     sleep 15
     COUNT=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
     echo "After reload $i: $COUNT containers"
   done
   ```

5. **Check Dozzle for ghosts:**
   ```bash
   ssh doc1 'docker logs management-dozzle-1 2>&1' | grep "no container with name or ID" | grep "jellyfin" | wc -l
   ```

6. **Expected result:** Container count increases by ~6-7 containers per reload (new IDs created, old ones left behind), and Dozzle logs show increasing ghost container errors

### Test 1: Remove --force-recreate from ExecReload only

**Hypothesis:** Reloads might not need force-recreate; podman-compose should detect changes and recreate only what's needed.

1. **Modify `stacks/lib/podman-compose.nix`:**
   ```nix
   ExecReload = "${podmanCompose} -f ${composeFile} ${mkEnvArgs envFiles} up -d --remove-orphans";
   # Removed --force-recreate from reload, kept in start
   ```

2. **Rebuild and deploy:**
   ```bash
   nixos-rebuild switch --flake .#igpu
   ```

3. **Clean slate:**
   ```bash
   sudo systemctl stop jellyfin-stack.service
   podman container prune -f --filter "label=io.podman.compose.project=jellyfin"
   ```

4. **Start fresh:**
   ```bash
   sudo systemctl start jellyfin-stack.service
   sleep 10
   BASELINE=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
   echo "Baseline: $BASELINE containers"
   ```

5. **Perform 5 reload cycles:**
   ```bash
   for i in {1..5}; do
     echo "=== Reload cycle $i ==="
     sudo systemctl reload jellyfin-stack.service
     sleep 15
     COUNT=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
     RUNNING=$(podman ps --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
     EXITED=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --filter "status=exited" --format "{{.ID}}" | wc -l)
     echo "After reload $i: Total=$COUNT (Running=$RUNNING, Exited=$EXITED)"
   done
   ```

6. **Check Dozzle for ghosts:**
   ```bash
   ssh doc1 'docker logs --tail 100 management-dozzle-1 2>&1' | grep "no container with name or ID" | tail -10
   ```

7. **Success criteria:**
   - Total container count stays at baseline (or close to it)
   - No accumulation of exited containers
   - Container IDs remain stable across reloads
   - **No new ghost container errors in Dozzle logs**

### Test 2: Remove --force-recreate from both ExecStart and ExecReload

**Hypothesis:** If Test 1 passes, try removing from both.

1. **Modify `stacks/lib/podman-compose.nix`:**
   ```nix
   ExecStart = "${podmanCompose} -f ${composeFile} ${mkEnvArgs envFiles} up -d --remove-orphans";
   ExecReload = "${podmanCompose} -f ${composeFile} ${mkEnvArgs envFiles} up -d --remove-orphans";
   # Removed --force-recreate from both
   ```

2. **Rebuild and deploy:**
   ```bash
   nixos-rebuild switch --flake .#igpu
   ```

3. **Clean slate:**
   ```bash
   sudo systemctl stop jellyfin-stack.service
   podman container prune -f --filter "label=io.podman.compose.project=jellyfin"
   ```

4. **Perform 5 restart cycles (full stop/start):**
   ```bash
   for i in {1..5}; do
     echo "=== Restart cycle $i ==="
     sudo systemctl restart jellyfin-stack.service
     sleep 15
     COUNT=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
     RUNNING=$(podman ps --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
     EXITED=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --filter "status=exited" --format "{{.ID}}" | wc -l)
     echo "After restart $i: Total=$COUNT (Running=$RUNNING, Exited=$EXITED)"
   done
   ```

5. **Check Dozzle for ghosts:**
   ```bash
   ssh doc1 'docker logs --tail 100 management-dozzle-1 2>&1' | grep "no container with name or ID" | tail -10
   ```

6. **Success criteria:**
   - No accumulation of containers across restarts
   - Exited container count stays at 0 or minimal
   - Container IDs remain stable
   - **No new ghost container errors in Dozzle logs**

### Test 3: Stress test with failed down commands

**Hypothesis:** The original issue was `podman-compose down` failing. Can we reproduce that?

1. **Simulate down failures:**
   ```bash
   # Start the stack
   sudo systemctl start jellyfin-stack.service
   sleep 10

   # Kill podman-compose processes mid-down to simulate failure
   sudo systemctl stop jellyfin-stack.service &
   sleep 2
   pkill -9 podman-compose

   # Try to start again - do containers accumulate?
   sudo systemctl start jellyfin-stack.service
   sleep 10
   COUNT=$(podman ps -a --filter "label=io.podman.compose.project=jellyfin" --format "{{.ID}}" | wc -l)
   echo "After simulated failure: $COUNT containers"
   ```

2. **Repeat 3 times to see if accumulation occurs**

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
