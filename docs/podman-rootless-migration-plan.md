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
- **Secrets per stack**: Each stack's `docker-compose.nix` imports its own secrets via `config.homelab.secrets.sopsFile`. Secrets are NOT defined in `configuration.nix` - they're self-contained in the stack module. This ensures secrets only exist when the stack is enabled.
- **Stack enablement**: Stacks are enabled via `hosts.nix` `containerStacks` list, not via imports in `configuration.nix`. The `containers-stacks.nix` module maps stack names to their modules.

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
- 2026-01-22: Renamed `podman-prune` to `podman-rootless-prune` to avoid nixpkgs module conflict.
- 2026-01-22: Plex stack enabled on igpu; fixed existing uid 99 data ownership with root chown.
- 2026-01-22: Jellyfin stack validated working on igpu clone (GPU passthrough dependent on Proxmox host).
- 2026-01-22: IGPU testing complete. Starting doc1 (proxmox-vm) clone testing.
- 2026-01-22: Added `nfsLocal.readOnly` option to nfs-local.nix module; enabled on doc1 clone for safety testing.
- 2026-01-22: Cleared `containerStacks` for doc1 - will enable stacks one by one.
- 2026-01-22: Fixed tailscale-caddy preStart: existing root-owned data can't use `podman unshare chown`; switched to root `chown -R 1000:1000`.
- 2026-01-22: Created `secrets/management.env` placeholder (copied from igpu-management.env).
- 2026-01-22: Fixed immich postgres crash loop: added `:U` volume flag for uid namespace mapping inside container.
- 2026-01-22: Doc1 stacks validated: tailscale-caddy, management, immich (all healthy).
- 2026-01-22: Paperless prepared with preStart + `:U` postgres volume; next batch: paperless, mealie, kopia, atuin, audiobookshelf.
- 2026-01-22: Doc1 paperless validated (rootless OK, all containers healthy).
- 2026-01-22: Mealie failed initially due to postgres permissions; fixed with `:U` on pgdata and preStart mkdir+chown. Mealie validated healthy.
- 2026-01-22: Hit registry rate limits during further stack testing; paused after mealie.
- 2026-01-22: Doc1 kopia validated (rootless OK, both instances healthy).
- 2026-01-22: Atuin failed initially due to postgres permissions; fixed with `:U` on pgdata and preStart mkdir+chown. Atuin validated healthy.
- 2026-01-22: Audiobookshelf validated healthy.
- 2026-01-22: Domain-monitor failed initially (env perms, missing DATA_ROOT, build context). Fixed by copying compose to /tmp build dir, adding DATA_ROOT, PATH, preStart mkdir/chown, and chowning env. Domain-monitor validated healthy and cron job runs.
- 2026-01-22: Invoices initially failed due to missing data dirs and solr ownership. Fixed preStart mkdir/chown for all mounts, added `:U` to postgres volumes, and ran solr as user 0. Invoices validated healthy (docspell + firefly + caddy running).
- 2026-02-22: Started work on tautulli, stirlingpdg and youtarr. Currently in an unknown state, needs testing

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

## Doc1 Clone Checklist (proxmox-vm)
1. ✅ Clone the `proxmox-vm` (doc1) VM and verify it boots clean.
2. ✅ Apply the podman rootless branch and rebuild with zero stacks.
3. ✅ Ensure podman system service is active and socket responds:
   - `systemctl --user status podman-system-service`
   - `curl --unix-socket /run/user/1000/podman/podman.sock http://localhost/_ping`
4. ✅ Confirm mounts and storage:
   - `/mnt/docker` (DATA_ROOT)
   - `/mnt/data` (read-only for safety testing via `nfsLocal.readOnly`)
   - `/mnt/fuse`, `/mnt/mum`, `/mnt/appdata` as applicable
5. ✅ Validate sops identity and that secrets decrypt when stacks are enabled.
6. Enable stacks one by one via `hosts.nix` `containerStacks`:
   - [x] tailscale-caddy - fixed preStart to use root chown instead of podman unshare
   - [x] management - added preStart for dozzle/gotify data dirs, created management.env placeholder
   - [x] immich - fixed preStart, added `:U` to postgres volume for uid mapping
   - [x] paperless - preStart + `:U` to postgres, validated healthy
   - [x] mealie - fixed pgdata permissions (`:U` + preStart chown), validated healthy
   - [x] kopia - validated healthy
   - [x] atuin - fixed pgdata permissions (`:U` + preStart chown), validated healthy
   - [x] audiobookshelf - validated healthy
   - [x] domain-monitor - fixed build context + DATA_ROOT + env perms, validated healthy + cron ok
   - [x] invoices - fixed mount prep + solr permissions, validated healthy
   - [ ] jdownloader2
   - [ ] music (needs PUID=0 update)
   - [ ] netboot
   - [ ] smokeping
   - [ ] stirlingpdf
   - [ ] tautulli
   - [ ] uptime-kuma
   - [ ] webdav
   - [ ] youtarr
7. For each stack: validate UI/health, check logs, verify auto-update labels.
8. Record permission issues and fix with tmpfiles + preStart chown.

### Doc1 Fixes Applied
- `tailscale-caddy`: Changed `podman unshare chown` to root `chown -R 1000:1000` for existing data
- `management`: Added preStart with mkdir + chown for dozzle/gotify dirs; created `secrets/management.env` placeholder
- `immich`: Changed preStart to root chown; added `:U` flag to postgres volume for uid namespace mapping
- `paperless`: Added preStart with mkdir + chown; added `:U` to postgres volume
- `mealie`: Added `:U` to pgdata volume and preStart mkdir + chown for data/pgdata
- `atuin`: Added `:U` to pgdata volume and preStart mkdir + chown for config/database
- `domain-monitor`: Added DATA_ROOT + PATH env, copy compose/build files to /tmp, preStart mkdir/chown for data, fixed env perms, and set PermissionsStartOnly
- `invoices`: Added preStart mkdir/chown for all mounts, added `:U` on postgres volumes, and set solr to run as user 0 to avoid rootless chown failures

## Learnings / Gotchas

### NixOS Module Integration
- Avoid naming systemd services/timers that conflict with nixpkgs modules (e.g., `podman-prune` conflicts with upstream). Use unique names like `podman-rootless-prune`.
- `nix flake check` uses lazy evaluation and won't catch module option conflicts. These only surface at build time when the specific option is evaluated.

### Permissions & Ownership
- Rootless volumes sometimes need `:U` (e.g., Solr) so the container can write.
- **Postgres/databases require `:U`**: Database containers (postgres, mariadb) run as internal uid (e.g., 999) which maps to host uid 1999 in rootless. Without `:U`, the container can't access files chowned to host uid 1000. Add `:U` flag to database volume mounts.
- Avoid `:U` on NFS/virtiofs mounts; it can fail with `operation not permitted` on rootless. Prefer preStart `mkdir` + `podman unshare chown`.
- Use `podman unshare chown` for **new** rootless data dirs; run it as the service user (e.g., `runuser -u <user> -- podman unshare chown -R 0:0 ...`).
- For **existing** data with different uid ownership (e.g., uid 99 from old Docker), use root `chown` in preStart instead of `podman unshare`. The preStart runs as root via `PermissionsStartOnly=true`.
- **Existing root-owned dirs block podman unshare**: If a directory is owned by actual root (uid 0) with mode 0700, `podman unshare chown` fails because the user namespace maps root→1000, not 0. Use root chown in preStart instead.
- Caddy needs write access to `/data` and `/config` for TLS storage. Pre-create and chown those host dirs.
- LSIO images often assume `PUID/PGID`; in rootless, `PUID=0` maps to the real host user (uid 1000). This avoids permission errors for `/config`.

### Podman Runtime
- Rootless Podman socket lives at `XDG_RUNTIME_DIR/podman/podman.sock`; ensure the podman system service is running and the socket responds (agent stacks will fail otherwise).
- Rootless Podman requires `newuidmap/newgidmap` available in service PATH; include `/run/wrappers/bin`.
- `restartIfChanged = true` restarts a stack when its systemd unit changes (compose/env changes will update the unit). Rebuilds that don't change the stack do not restart it.

### Compose & Containers
- `podman-compose` dependency handling is strict; missing healthchecks can block startup.
- Tailscale containers in sandbox require a bypass for healthchecks; prod must use real auth.
- Tailscale sidecars run fine rootless with `/dev/net/tun` + `NET_ADMIN`; iptables v6 warnings are expected on minimal kernels.
- Caddyfile paths must be provided via `CADDY_FILE` env (test harness defaults to stack-local files).
- Jellystat requires a Jellyfin URL; set `JELLYFIN_URL=http://jellyfin:8096` when sharing the stack network.

### Testing & Operations
- If a rebuild is interrupted, `systemd-run` can leave `nixos-rebuild-switch-to-configuration` around; stop/reset it before rerunning.
- Netboot TFTP on privileged port needs an override (`TFTP_PORT`) for rootless tests.
- Docker Hub rate limits can block sandbox pulls; prod testing should authenticate or pre-pull.
- Sandbox disk space can be tight for large images (e.g., Ollama); clean storage or use a larger test VM.
- Always prune before stack testing in sandbox to avoid overlay storage bloat.

## Stack Status (Rootless Readiness)

### Validated on igpu clone
- **jellyfin** - PUID=0, tmpfiles + preStart with chown
- **plex** - PUID=0, tmpfiles + preStart with root chown (existing uid 99 data)
- **tdarr-igp** - PUID=0, tmpfiles + preStart
- **igpu-management** - No persistent data (autoheal + dozzle-agent only)

### Need PUID/PGID update before enabling
- **music** - lidarr/ombi use PUID=99, filebrowser uses user: "99:100" → change to PUID=0
- **nicotine** - PUID=99 → change to PUID=0

### Likely OK (PUID=1000 maps to host user)
- **smokeping** - PUID=1000
- **syncthing** - PUID=1000

### Not yet audited
All other stacks in `docker/` - check when enabling:
1. Add tmpfiles rules for data directories
2. Add preStart with mkdir + chown (root chown for existing data, podman unshare for new)
3. Update PUID/PGID to 0 for LSIO images

## Known Issues

### Dozzle agent not showing all containers
- **Symptom**: Dozzle UI shows some stacks (jellyfin, tdarr, igpu-management) but not others (plex), despite all containers being visible via `podman ps` and the socket API.
- **Verified**: Socket returns all containers correctly; labels are identical between visible and invisible stacks.
- **Workaround**: Use lazydocker for now.
- **TODO**: Investigate Dozzle + rootless podman compatibility. Check Dozzle GitHub issues. May need agent restart after new stacks, or there's a container discovery bug.

## Wishlist
- Virtiofs-backed `/mnt/docker` from Proxmox host (separate storage from runtime).
- Convert podman-compose stacks to quadlet units once rootless is stable.
