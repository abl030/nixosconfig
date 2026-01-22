# Proxmox-VM (Doc1) Rootless Podman Testing Plan

## Overview

This document outlines the testing plan for migrating proxmox-vm (doc1) stacks to rootless Podman.
Testing should be done on a **clone** of the production doc1 VM.

## Current Status (2026-01-22)

- Clone is running with `/mnt/data` mounted read-only for safety.
- Validated stacks on the doc1 clone: `tailscale-caddy`, `management`, `immich`, `paperless`, `mealie`.
- Mealie required pgdata permissions fixes (`:U` on pgdata + preStart mkdir/chown).
- Further stack testing paused due to registry rate limits.

## Pre-Testing Checklist

### 1. Clone the VM
```bash
# On Proxmox host - create a clone of doc1 (VMID 104)
./vms/proxmox-ops.sh clone 104 <new-vmid> doc1-test
```

### 2. Apply the podman-rootless branch
```bash
# On the cloned VM
cd /home/abl030/nixosconfig
git fetch origin feat/podman-rootless
git checkout feat/podman-rootless
sudo nixos-rebuild switch --flake .#proxmox-vm
```

### 3. Verify Podman infrastructure
```bash
# Check podman system service
systemctl status podman-system-service

# Test socket responds
curl --unix-socket /run/user/1000/podman/podman.sock http://localhost/_ping

# Verify storage config
cat /etc/containers/storage.conf
```

### 4. Verify mounts exist
- `/mnt/docker` - container data root
- `/mnt/data` - NFS media mount
- `/mnt/fuse` - rclone fuse mount (if applicable)
- `/mnt/paperless` - paperless data
- Any other mounts required by specific stacks

### 5. Verify secrets
```bash
# Check sops identity exists
ls -la /var/lib/sops-nix/key.txt

# Test decryption works
sops -d /home/abl030/nixosconfig/secrets/some-secret.env
```

## Stacks to Test (19 total)

### Tier 1: Core Infrastructure (test first)
| Stack | Port(s) | Health Check | Notes |
|-------|---------|--------------|-------|
| management | 7007 (dozzle) | Dozzle UI loads | Autoheal + Dozzle for monitoring |
| tailscale-caddy | 80, 443 | curl localhost | Main reverse proxy |

### Tier 2: Media & Content
| Stack | Port(s) | Health Check | Notes |
|-------|---------|--------------|-------|
| immich | 2283 | Web UI loads | Photos - has DB |
| audiobookshelf | 13378 | Web UI loads | Audiobooks |
| music | 8686, 3579, 8085 | Lidarr ping | Lidarr + Ombi + Filebrowser |
| tautulli | 8181 | Web UI loads | Plex stats |
| youtarr | 3087 | Web UI loads | YouTube downloads - has DB |

### Tier 3: Documents & Productivity
| Stack | Port(s) | Health Check | Notes |
|-------|---------|--------------|-------|
| paperless | 8000 | Web UI loads | Document management |
| mealie | 9925 | Web UI loads | Recipes - has DB |
| invoices | 9000 | Web UI loads | Invoice Ninja - has DB |
| stirlingpdf | 8080 | Web UI loads | PDF tools |
| webdav | 9090 | stat endpoint | Zotero sync |

### Tier 4: Utilities & Monitoring
| Stack | Port(s) | Health Check | Notes |
|-------|---------|--------------|-------|
| kopia | 51515 | Web UI loads | Backups |
| atuin | 8888 | API responds | Shell history sync |
| domain-monitor | 3000 | Web UI loads | Domain monitoring |
| uptime-kuma | 3001 | Web UI loads | Uptime monitoring |
| smokeping | 8084 | Web UI loads | Network latency |

### Tier 5: Downloads & Network
| Stack | Port(s) | Health Check | Notes |
|-------|---------|--------------|-------|
| jdownloader2 | 5800 | Web UI loads | Downloads |
| netboot | 69 (TFTP), 8083 | TFTP test | PXE boot - needs privileged port workaround |

## Testing Procedure

### For each stack:

1. **Start the stack**
   ```bash
   sudo systemctl start <stack-name>-stack
   ```

2. **Check service status**
   ```bash
   systemctl status <stack-name>-stack
   ```

3. **Verify containers running**
   ```bash
   sudo -u abl030 XDG_RUNTIME_DIR=/run/user/1000 podman ps --filter "label=com.docker.compose.project=<project>"
   ```

4. **Check logs for errors**
   ```bash
   sudo -u abl030 XDG_RUNTIME_DIR=/run/user/1000 podman logs <container-name>
   ```

5. **Test health endpoint**
   ```bash
   curl -s http://localhost:<port>/
   ```

6. **Check for permission errors**
   - Look for "permission denied" in logs
   - Check volume mount ownership

### If stack fails:

1. Check journalctl for systemd errors:
   ```bash
   journalctl -u <stack-name>-stack -n 50
   ```

2. Common fixes:
   - **Permission denied on volumes**: Add preStart with `chown` to docker-compose.nix
   - **Container won't start**: Check if existing data has wrong ownership (use root chown)
   - **Port binding fails**: Rootless can't bind <1024, add port override

3. After fixing, rebuild:
   ```bash
   sudo nixos-rebuild switch --flake .#proxmox-vm
   ```

## PUID/PGID Status

Do not assume all stacks are updated. Verify per stack before enabling.
- Updated/verified: mealie
- Still needs attention: music (lidarr/ombi/filebrowser PUID updates)

## Known Issues from igpu Testing

1. **Dozzle container visibility**: Some stacks may not appear in Dozzle UI despite running. Workaround: use lazydocker.

2. **Existing data ownership**: If container data was created by old Docker with different UIDs (e.g., uid 99), use root `chown` in preStart instead of `podman unshare chown`.

3. **NFS mount permissions**: Avoid `:U` volume flag on NFS mounts. Use explicit ownership setup in preStart.

## Post-Testing

After all stacks pass testing:

1. Update `docs/podman-rootless-migration-plan.md` with any new learnings
2. Commit all fixes to the branch
3. Plan production migration window for doc1

## Rollback Plan

If testing reveals major issues:
1. The production doc1 remains untouched on old Docker setup
2. Destroy the test clone
3. Address issues in the branch before retrying
