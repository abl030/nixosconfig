# Podman Current State

Last updated: 2026-02-15
Status: Phase 2 complete and stable

## What Is Running

1. Rootless Podman + compose-managed stacks in user scope (`${stackName}.service`).
2. Stack deploy command: `podman compose up -d --remove-orphans`.
3. Stack updates: scheduled compose pull/redeploy (`*-update.service`), not `podman auto-update`.
4. Compose provider is pinned to `docker compose` via `PODMAN_COMPOSE_PROVIDER`.
5. `docker-client` is installed as required runtime dependency.
6. Home Manager owns stack unit files in `~/.config/systemd/user`.
7. Provenance/reconciliation checks remain enabled.

## Why This Model

1. Podman auto-update on compose-managed containers is not reliable in this environment (`RawImageName` gap on compat path).
2. Compose pull/redeploy is deterministic and currently working on `doc1` and `igpu`.
3. App-level monitoring is the readiness signal (not deploy-time compose wait gating).

## Accepted Residual Risks

1. Oneshot restart exit semantics are not equivalent to full app readiness.
2. Manual destructive tampering of user/systemd unit artifacts can still break convergence.
3. Rare stale container dependency/orphan states may require forced cleanup and restart.

These risks are accepted for current homelab operations.
