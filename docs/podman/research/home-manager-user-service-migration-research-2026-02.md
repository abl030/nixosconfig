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
