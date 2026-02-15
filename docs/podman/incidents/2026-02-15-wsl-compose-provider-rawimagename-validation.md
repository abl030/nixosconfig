# WSL Validation: docker compose Provider vs RawImageName

Date: 2026-02-15  
Status: PASS (hypothesis tested, disproven)  
Host: `wsl`

## Hypothesis

Pinning `podman compose` to use `docker compose` and recreating compose-managed containers will populate metadata needed by Podman auto-update (`RawImageName`).

## Test Steps

1. Confirm current `podman auto-update --dry-run` failure shape on compose probe stacks (`restart-probe*`) with `raw-image name is empty`.
2. Pin compose provider via `PODMAN_COMPOSE_PROVIDER` to wrapper executing `docker compose`.
3. Rebuild local host (`nixos-rebuild test --flake .#wsl`).
4. Force-recreate compose probe containers:
   - remove probe containers
   - restart probe stack services
5. Re-run `podman auto-update --dry-run`.
6. Verify provider in stack logs (`journalctl --user -u restart-probe-stack.service`).

## Observed Results

1. New container IDs were created for both probe stacks after forced recreation.
2. Logs confirmed provider switched to wrapper path (`/nix/store/...-podman-compose-provider`) executing `docker compose`.
3. `podman auto-update --dry-run` still failed for recreated compose containers with:
   - `locally auto-updating container "<id>": raw-image name is empty`
4. Non-compose probe container (`autoupdate-probe`) remained valid in auto-update output.

## Conclusion

1. Hypothesis disproven.
2. Pinning provider to `docker compose` does **not** fix missing `RawImageName` metadata for compose-managed containers in this environment.
3. Current strategy remains correct:
   - do not rely on Podman compat-path auto-update for compose stacks,
   - use compose pull/redeploy update units.
