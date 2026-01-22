# Podman Rootless Migration Plan

## Goals
- Replace Docker + sudo containers with Podman rootless everywhere.
- Standardize auto-update via Podman labels + timers.
- Keep Dozzle for logs.
- Provide a reproducible test harness for stack validation.

## Architecture Changes
- Nix module enables rootless Podman, userns, and base tools.
- Systemd user-level Podman socket (`podman-system-service`).
- Podman auto-update service + timer.
- Compose stacks run as the homelab user with `podman-compose`.

## Compose Conventions
- Data mounts: replace `/mnt/docker/...` with `${DATA_ROOT}/...`.
- Host media mounts: `${MEDIA_ROOT:-/mnt/data}`, `${FUSE_ROOT:-/mnt/fuse}`, `${MUM_ROOT:-/mnt/mum}`, `${UNRAID_ROOT:-/mnt/user}`.
- Other mounts: `${PAPERLESS_ROOT:-/mnt/paperless}`, `${NICOTINE_ROOT:-/mnt/nicotine-plus}`, `${CONTAINERS_ROOT:-/Containers}`, `${SYNC_DATA_ROOT:-/mnt/docker/syncthing/data}`.
- Podman socket: mount `${XDG_RUNTIME_DIR}/podman/podman.sock` to `/var/run/docker.sock` inside containers.
- Explicit image registries where possible to avoid short-name prompts.
- Auto-update labels on all non-domain services: `io.containers.autoupdate=registry`.

## Testing System (Sandbox)
### Test Harness Concept
- Run each stack individually with a synthetic mount root.
- Provide default env var values for secrets and required config.
- Validate containers are running and not unhealthy.

### Test Harness (Implementation)
- `scripts/podman-stack-test.sh`: stack runner with optional `--timeout` and `--verbose`.
- `scripts/podman-test-all.sh`: batch runner with report output.
- Report is written to `docs/podman-test-report.md`.

## Next Concrete Actions
1. Test in prod-like conditions on a cloned `igpu` VM (rootless Podman enabled, real mounts + secrets).
2. Run each stack one by one and verify actual service readiness (not just container start).
3. Confirm auto-update timers and Dozzle socket access under rootless Podman.
4. Prepare virtiofs-backed `/mnt/docker` on Proxmox and switch prod to virtiofs mounts.

## Progress Log
- 2026-01-21: Podman tooling + userns enabled in sandbox host config.
- 2026-01-21: Added sandbox test runner `scripts/podman-stack-test.sh`.
- 2026-01-21: Converted stack services to podman-compose rootless (system services run as user).
- 2026-01-21: Replaced `/mnt/docker` in compose files with `${DATA_ROOT}` and updated podman socket mounts.
- 2026-01-21: Removed Watchtower and enabled Podman auto-update timer support.
- 2026-01-21: Added test harness defaults for stack-local `Caddyfile` and `tailscale` JSON config.
- 2026-01-21: Adjusted Tailscale healthchecks to allow sandbox validation without auth.
- 2026-01-21: Added Immich DB healthcheck for podman-compose dependency handling.
- 2026-01-21: Resolved Docspell Solr rootless permissions with `:U` volume.
- 2026-01-21: Podman storage configured to use `${DATA_ROOT}/containers` (rootless graphroot).
- 2026-01-22: Added `newuidmap/newgidmap` wrappers and PATH fixes for rootless systemd services.
- 2026-01-22: Added placeholder SOPS envs for stacks without secrets (`igpu-management`, `plex`, `tdarr-igp`).
- 2026-01-22: Enforced `/mnt/data` read-only on igpu clone to surface write assumptions.

## Prod Testing Plan (igpu clone)
1. Clone the `igpu` VM and apply the podman-rootless branch.
2. Ensure real mounts exist: `/mnt/docker`, `/mnt/data`, `/mnt/fuse`, `/mnt/mum`, `/mnt/user`, `/mnt/paperless`, `/mnt/nicotine-plus`.
3. Confirm secrets are available (sops identity + decrypted envs).
4. Start stacks one-by-one; after each start, validate:
   - service health endpoints or UI load
   - logs free of permission/auth errors
   - auto-update labels present for non-domain containers
   - Dozzle visible and listing containers
5. Capture issues and update compose files/modules as needed.

## IGPU Clone Checklist (Reset State)
1. Clone the `igpu` VM and verify it boots clean.
2. Apply the podman rootless branch and rebuild.
3. Ensure podman system service is active and socket responds:
   - `systemctl status podman-system-service`
   - `curl --unix-socket /run/user/1000/podman/podman.sock http://localhost/_ping`
4. Confirm mounts and storage:
   - `/mnt/docker` (future virtiofs target)
   - `/mnt/data` (NFS from Unraid; optionally read-only for safety testing)
   - `/mnt/fuse`, `/mnt/mum`, `/mnt/user`, `/mnt/paperless`, `/mnt/nicotine-plus` as applicable
5. Validate secrets (sops identity, decrypted envs) before starting stacks.
   - Ensure placeholder envs exist for stacks without secrets (igpu-management, plex, tdarr-igp).
6. Start stacks one-by-one; after each, validate UI/health endpoints and logs.
7. Verify auto-update labels are present and timer is active.
8. Validate Dozzle UI/agent access to the rootless socket.
9. Record any permissions issues on mounted volumes and adjust `:U` or ownership.

## Learnings / Gotchas
- Rootless volumes sometimes need `:U` (e.g., Solr) so the container can write.
- `podman-compose` dependency handling is strict; missing healthchecks can block startup.
- Tailscale containers in sandbox require a bypass for healthchecks; prod must use real auth.
- Caddyfile paths must be provided via `CADDY_FILE` env (test harness defaults to stack-local files).
- Rootless Podman socket lives at `XDG_RUNTIME_DIR/podman/podman.sock`; ensure the podman system service is running and the socket responds (agent stacks will fail otherwise).
- Rootless Podman requires `newuidmap/newgidmap` available in service PATH; include `/run/wrappers/bin`.
- `restartIfChanged = true` restarts a stack when its systemd unit changes (compose/env changes will update the unit). Rebuilds that don't change the stack do not restart it.
- Use `podman unshare chown` for rootless data dirs; run it as the service user (e.g., `runuser -u <user> -- podman unshare chown -R 0:0 ...`) to avoid “please use unshare with rootless”.
- Avoid `:U` on NFS/virtiofs mounts; it can fail with `operation not permitted` on rootless. Prefer preStart `mkdir` + `podman unshare chown`.
- Caddy needs write access to `/data` and `/config` for TLS storage. Pre-create and chown those host dirs to `0:0` via `podman unshare`.
- LSIO images often assume `PUID/PGID`; in rootless, `PUID=0` maps to the real host user (uid 1000). This avoids permission errors for `/config`.
- Jellystat requires a Jellyfin URL; set `JELLYFIN_URL=http://jellyfin:8096` when sharing the stack network.
- Tailscale sidecars run fine rootless with `/dev/net/tun` + `NET_ADMIN`; iptables v6 warnings are expected on minimal kernels.
- If a rebuild is interrupted, `systemd-run` can leave `nixos-rebuild-switch-to-configuration` around; stop/reset it before rerunning.
- Netboot TFTP on privileged port needs an override (`TFTP_PORT`) for rootless tests.
- Docker Hub rate limits can block sandbox pulls; prod testing should authenticate or pre-pull.
- Sandbox disk space can be tight for large images (e.g., Ollama); clean storage or use a larger test VM.
- Always prune before stack testing in sandbox to avoid overlay storage bloat.

## Wishlist
- Virtiofs-backed `/mnt/docker` from Proxmox host (separate storage from runtime).
- Convert podman-compose stacks to quadlet units once rootless is stable.
