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
