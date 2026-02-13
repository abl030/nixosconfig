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
6. Unit files for stack services are currently generated from NixOS into `/etc/systemd/user/...`.

## Rebuild and Change Propagation

1. Compose and env file changes are represented as new Nix store paths and updated unit references.
2. Rebuild does not use compose health gating (`--wait`), so activation is not blocked on runtime health convergence.
3. A documented `igpu` test showed that stale user-level unit artifacts in `~/.config/systemd/user` can cause restarts to continue using old unit definitions even when `/etc/systemd/user` is updated.
4. In that test, removing stale user-level unit artifacts switched `FragmentPath` to `/etc/systemd/user/...` and the updated compose command was then observed.
5. This is now treated as an ownership-collision risk between unit sources, not a compose-wrapper bug.

Evidence: `docs/podman/incidents/2026-02-13-compose-change-propagation-test.md`

## Phase 2.5 Direction (Accepted, Not Yet Implemented)

1. Keep stack lifecycle in user scope (`${stackName}.service` remains user service).
2. Migrate unit ownership from NixOS `/etc/systemd/user` generation to Home Manager `~/.config/systemd/user` generation.
3. Enforce single ownership per unit name (no dual definition across `/etc/systemd/user` and `~/.config/systemd/user`).
4. Add post-switch ownership checks using `FragmentPath` and `DropInPaths` as operational invariants.
5. Treat "user manager unavailable" as a reconciliation failure condition that must be surfaced explicitly.

Implementation plan: `docs/podman/current/phase2.5-home-manager-migration-plan.md`

## Related Records

- Decision record: `docs/podman/decisions/2026-02-12-container-lifecycle-strategy.md`
- Ownership decision update: `docs/podman/decisions/2026-02-13-home-manager-user-unit-ownership.md`
- Research summary: `docs/podman/research/container-lifecycle-analysis-2026-02.md`
- Ownership migration research: `docs/podman/research/home-manager-user-service-migration-research-2026-02.md`
- Historical implementation plan: `docs/podman/archive/plans/2026-02-13-phase2-execution-plan.md`
