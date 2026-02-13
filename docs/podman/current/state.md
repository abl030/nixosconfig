# Podman Current State

Last updated: 2026-02-13

## Scope

This document records current, observed behavior for container stacks managed by `stacks/lib/podman-compose.nix`.

## Runtime Model

1. Stack lifecycle owner is the user unit `${stackName}.service`.
2. Deploy path is `podman compose up -d --remove-orphans` (no deploy-time `--wait`).
3. Startup timeout is bounded (`startupTimeoutSeconds`, default 300 seconds).
4. Env files are sourced from system-scope `sops.secrets` paths; legacy fallback support exists for one release.
5. Auto-update invariant is enforced as hard-fail:
   - If `io.containers.autoupdate=registry` is present, `PODMAN_SYSTEMD_UNIT` must be present.

## Rebuild and Change Propagation

1. Compose and env file changes are represented as new Nix store paths and updated unit references.
2. Rebuild does not use compose health gating (`--wait`), so activation is not blocked on runtime health convergence.
3. A documented `igpu` test showed that stale user-level unit artifacts in `~/.config/systemd/user` can cause restarts to continue using old unit definitions even when `/etc/systemd/user` is updated.
4. In that test, removing stale user-level unit artifacts switched `FragmentPath` to `/etc/systemd/user/...` and the updated compose command was then observed.

Evidence: `docs/podman/incidents/2026-02-13-compose-change-propagation-test.md`

## Related Records

- Decision record: `docs/podman/decisions/2026-02-12-container-lifecycle-strategy.md`
- Research summary: `docs/podman/research/container-lifecycle-analysis-2026-02.md`
- Historical implementation plan: `docs/podman/archive/plans/2026-02-13-phase2-execution-plan.md`
