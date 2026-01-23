# Container Stacks

This directory contains all rootless Podman container stack definitions for the homelab infrastructure.

## Architecture Overview

### Three-Level Self-Contained Design

**Level 1: Podman Infrastructure** (`modules/nixos/homelab/containers/default.nix`)
- Enables rootless podman with complete runtime setup
- Configures subuid/subgid ranges (100000-165535)
- Sets up storage with overlay driver and fuse-overlayfs
- Runs `podman-system-service.service` for API access
- Provides automatic container updates (daily by default)
- Provides automatic cleanup/pruning (weekly, 7-day retention by default)
- All infrastructure state contained in `homelab.containers.*` options

**Level 2: Stack Registry** (`modules/nixos/homelab/containers/stacks.nix`)
- Maps stack names to their Nix module paths
- Reads `containerStacks` list from `hosts.nix`
- Dynamically imports only enabled stacks
- Validates stack names exist in registry
- No manual imports needed in host configurations

**Level 3: Individual Stacks** (this directory)
- Each stack is fully self-contained in its directory
- Declares all requirements via `mkService` parameters:
  - `secrets` → encrypted env files via sops-nix
  - `requiresMounts` → filesystem dependencies
  - `firewallPorts` → TCP ports to open
  - `preStart` → initialization scripts
  - `wants/after/requires` → systemd dependencies
- Stack state isolated to its directory
- Enable/disable declaratively via `hosts.nix`

### Enabling Stacks

Add stack names to `hosts.nix`:

```nix
{
  proxmox-vm = {
    # ... other config
    containerStacks = [
      "management"
      "immich"
      "paperless"
      # ... more stacks
    ];
  };
}
```

Stacks are automatically imported and configured. No changes needed in `configuration.nix`.

## Directory Structure

```
stacks/
├── lib/
│   └── podman-compose.nix    # Shared mkService function
├── <stack-name>/
│   ├── docker-compose.nix    # Nix module (imports mkService)
│   ├── docker-compose.yml    # Container definitions
│   └── ...                   # Stack-specific files (Caddyfile, init.sql, etc.)
```

## Stack Module Pattern

Each `docker-compose.nix` follows this pattern:

```nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "myapp-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "myapp-docker-compose.yml";
  };

  # Optional: Secrets
  encEnv = config.homelab.secrets.sopsFile "myapp.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  # Optional: Additional files (Caddyfile, etc.)
  caddyFile = builtins.path {
    path = ./Caddyfile;
    name = "myapp-Caddyfile";
  };

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  inherit (config.homelab.containers) dataRoot;

  dependsOn = ["network-online.target" "mnt-data.mount"];
in
  podman.mkService {
    inherit stackName;
    description = "MyApp Podman Compose Stack";
    projectName = "myapp";
    inherit composeFile;
    inherit envFiles;  # Optional

    extraEnv = [  # Optional
      "CADDY_FILE=${caddyFile}"
    ];

    preStart = [  # Optional
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/myapp/data"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/myapp"
    ];

    requiresMounts = ["/mnt/data"];  # Optional
    wants = dependsOn;
    after = dependsOn;

    firewallPorts = [8080 8443];  # TCP ports to open
  }
```

## Compose File Conventions

### Environment Variables

All compose files use these variables:

- `DATA_ROOT` - Container persistent data root (default: `/mnt/docker`)
- `MEDIA_ROOT` - Media files (default: `/mnt/data`)
- `FUSE_ROOT` - Fuse mounts (default: `/mnt/fuse`)
- `MUM_ROOT` - Mum NFS mount (default: `/mnt/mum`)
- `UNRAID_ROOT` - Unraid NFS mount (default: `/mnt/user`)

**Usage:**
```yaml
volumes:
  - ${DATA_ROOT}/myapp:/config
  - ${MEDIA_ROOT:-/mnt/data}/Media:/media:ro
```

### Container User Mapping

**Rootless podman uses user namespace mapping:**
- Container uid 0 → Host uid 1000 (your user)
- Container uid 1 → Host uid 100001
- Container uid 999 → Host uid 100999

**For LSIO images (linuxserver.io):**
```yaml
environment:
  - PUID=0  # Maps to host uid 1000
  - PGID=0  # Maps to host gid 1000
```

**For standard images:**
```yaml
user: "0:0"  # Run as container root (host user)
```

### Volume Permissions

**The `:U` flag for database containers:**

Database containers (postgres, mariadb) run as internal uid (e.g., 999) which maps to host uid 100999 in rootless mode. Without `:U`, the container cannot access files owned by host uid 1000.

```yaml
volumes:
  - ${DATA_ROOT}/myapp/pgdata:/var/lib/postgresql/data:U
```

**When to use `:U`:**
- Postgres, MariaDB, MySQL data directories
- Containers that run as non-root internally
- Solr and other Java applications

**When NOT to use `:U`:**
- NFS mounts (will fail with "operation not permitted")
- Virtiofs mounts
- Data owned by LSIO containers using PUID=0

### Auto-Update Labels

All containers should have auto-update enabled:

```yaml
labels:
  - io.containers.autoupdate=registry
```

Podman auto-update runs daily and pulls latest images with this label.

### Image Registries

Use explicit registries to avoid short-name prompts:

```yaml
# Good
image: docker.io/library/postgres:16
image: ghcr.io/linuxserver/jellyfin:latest
image: lscr.io/linuxserver/plex:latest

# Bad (ambiguous)
image: postgres:16
image: jellyfin:latest
```

### Podman Socket for Agent Containers

For containers that need Docker API access (Dozzle, Watchtower, etc.):

```yaml
volumes:
  - ${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/docker.sock:ro
```

## Creating a New Stack

### 1. Create Stack Directory

```bash
mkdir stacks/mynewapp
cd stacks/mynewapp
```

### 2. Convert docker-compose.yml

**Update paths:**
- Replace `/mnt/docker/...` → `${DATA_ROOT}/...`
- Replace hardcoded media paths → `${MEDIA_ROOT:-/mnt/data}/...`

**Update user/permissions:**
```yaml
environment:
  - PUID=0  # For LSIO images
  - PGID=0
# OR
user: "0:0"  # For standard images
```

**Add volume flags if needed:**
```yaml
volumes:
  - ${DATA_ROOT}/mynewapp/pgdata:/var/lib/postgresql/data:U  # Database containers
```

**Add labels:**
```yaml
labels:
  - io.containers.autoupdate=registry
```

### 3. Create docker-compose.nix

```nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "mynewapp-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "mynewapp-docker-compose.yml";
  };

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  inherit (config.homelab.containers) dataRoot;

  dependsOn = ["network-online.target"];
in
  podman.mkService {
    inherit stackName;
    description = "MyNewApp Podman Compose Stack";
    projectName = "mynewapp";
    inherit composeFile;

    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/mynewapp"
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/mynewapp"
    ];

    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [8080];  # List TCP ports to expose
  }
```

### 4. Add Secrets (if needed)

Create encrypted env file:
```bash
cd secrets
sops mynewapp.env
```

Update docker-compose.nix:
```nix
let
  encEnv = config.homelab.secrets.sopsFile "mynewapp.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];
in
  podman.mkService {
    # ...
    inherit envFiles;
  }
```

### 5. Register Stack

Edit `modules/nixos/homelab/containers/stacks.nix`:

```nix
stackModules = {
  # ... existing stacks
  mynewapp = ../../../../stacks/mynewapp/docker-compose.nix;
};
```

### 6. Enable on Host

Edit `hosts.nix`:

```nix
{
  myhost = {
    # ...
    containerStacks = [
      # ... existing stacks
      "mynewapp"
    ];
  };
}
```

### 7. Deploy

```bash
nixos-rebuild switch --flake .#myhost
```

## Permission Scenarios & Solutions

### Scenario 1: New Stack, New Data

**Use podman unshare for correct uid mapping:**

```nix
preStart = [
  "/run/current-system/sw/bin/mkdir -p ${dataRoot}/mynewapp/data"
  "/run/current-system/sw/bin/runuser -u ${user} -- podman unshare chown -R 0:0 ${dataRoot}/mynewapp"
];
```

This creates directories owned by the host user (uid 1000) but visible as uid 0 inside containers.

### Scenario 2: Migrating from Docker (existing data owned by different uid)

**Use root chown in preStart:**

```nix
preStart = [
  "/run/current-system/sw/bin/mkdir -p ${dataRoot}/mynewapp"
  # Use root chown for existing data
  "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/mynewapp"
];
```

The preStart runs as root via `PermissionsStartOnly=true`, so it can change ownership of existing files.

**Why not podman unshare?** If existing directories are owned by actual root (uid 0) with mode 0700, podman unshare fails because the user namespace can't access them.

### Scenario 3: Database Container (postgres/mariadb)

**Always use `:U` volume flag:**

```yaml
volumes:
  - ${DATA_ROOT}/mynewapp/pgdata:/var/lib/postgresql/data:U
```

```nix
preStart = [
  "/run/current-system/sw/bin/mkdir -p ${dataRoot}/mynewapp/pgdata"
  "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/mynewapp"
];
```

Database containers run as uid 999 internally (postgres user), which maps to host uid 100999. The `:U` flag enables proper uid namespace mapping.

### Scenario 4: NFS/Network Mounts

**Never use `:U` on NFS/network mounts:**

```yaml
volumes:
  - /mnt/data/media:/media:ro  # No :U flag
```

NFS doesn't support the uid mapping operations that `:U` requires. Ensure the NFS export is accessible to your host user (uid 1000).

### Scenario 5: Optional/Slow Mounts (NFS over Tailscale)

**Use automount dependencies, not mount:**

```nix
let
  dependsOn = [
    "network-online.target"
    "mnt-data.mount"        # Required mount
    "mnt-mum.automount"     # Optional mount via automount
  ];
in
  podman.mkService {
    # Only list required mounts
    requiresMounts = ["/mnt/data"];
    # Don't include /mnt/mum - it's handled by automount dependency
    wants = dependsOn;
    after = dependsOn;
  }
```

**Why?** `RequiresMountsFor` creates a hard dependency on the mount unit. If the mount times out at boot, the service fails. Using `automount` allows the mount to happen on-demand with automatic retries.

## Common Gotchas & Learnings

### NixOS Module Integration

- **Avoid naming conflicts:** Don't name systemd services/timers that conflict with nixpkgs modules (e.g., `podman-prune` conflicts with upstream). Use unique names like `podman-rootless-prune`.
- **`nix flake check` limitations:** Uses lazy evaluation and won't catch module option conflicts. These only surface at build time when the specific option is evaluated.

### Permissions & Ownership

- **Database containers require `:U`:** Postgres, MariaDB, etc. run as internal uid (999) which maps to host uid 100999 in rootless. Without `:U`, the container can't access files owned by host uid 1000.
- **Never use `:U` on NFS:** It fails with "operation not permitted" on rootless. Use preStart mkdir + chown instead.
- **Use `podman unshare chown` for new data:** Creates correct ownership visible to both host and container.
- **Use root `chown` for existing data:** If directories are owned by different uid (like uid 99 from Docker) or actual root, use root chown in preStart instead of podman unshare.
- **Existing root-owned dirs block podman unshare:** If a directory is owned by actual root (uid 0) with mode 0700, podman unshare fails. Use root chown in preStart.
- **LSIO images use PUID/PGID:** In rootless, `PUID=0` maps to the real host user (uid 1000). This avoids permission errors for `/config`.
- **Caddy needs writable /data and /config:** Pre-create and chown those host directories for TLS certificate storage.

### Podman Runtime

- **Socket location:** Rootless podman socket lives at `$XDG_RUNTIME_DIR/podman/podman.sock` (typically `/run/user/1000/podman/podman.sock`).
- **newuidmap/newgidmap required:** Rootless podman needs these in PATH. Include `/run/wrappers/bin` in service PATH.
- **restartIfChanged behavior:** `restartIfChanged = true` restarts a stack when its systemd unit changes (compose/env changes update the unit). Rebuilds that don't change the stack do not restart it.

### Systemd Service & Mount Resilience

- **podman-system-service must wait for user runtime dir:** The service creates `/run/user/1000/podman`, but `/run/user/1000` is created by `user@1000.service`. Add `after` and `requires` dependencies.
- **RequiresMountsFor creates hard dependencies:** Using `requiresMounts` adds `RequiresMountsFor` which creates a hard dependency on the actual mount unit, not automount. Service fails if mount times out at boot.
- **Use automount for optional/slow mounts:** For NFS over Tailscale or slow networks, depend on `mnt-xxx.automount` instead of `mnt-xxx.mount`. Don't include such paths in `requiresMounts`.
- **bindsTo for coordinated restarts:** `bindsTo = ["podman-system-service.service"]` ensures stacks restart when podman service restarts.
- **StartLimitIntervalSec/Burst for retry tolerance:** Allows 5 restart attempts within 5 minutes for transient boot-time failures.
- **Dependency failures don't trigger Restart=on-failure:** When a service fails due to dependency failure, systemd doesn't retry even with `Restart=on-failure`. The `bindsTo` directive solves this.

### Compose & Containers

- **podman-compose dependency handling is strict:** Missing healthchecks can block startup. Add healthchecks to database containers.
- **Tailscale containers run fine rootless:** Require `/dev/net/tun` + `NET_ADMIN` capability. iptables v6 warnings are expected.
- **Caddyfile paths via env:** Provide via `CADDY_FILE` environment variable, not hardcoded paths.
- **Network holder pattern:** For multi-container stacks sharing ports, use a pause container as network holder and `network_mode: service:holder` for other containers.

### Testing & Operations

- **Interrupted rebuilds:** `systemd-run` can leave `nixos-rebuild-switch-to-configuration` processes. Stop/reset before rerunning.
- **Docker Hub rate limits:** Can block pulls. Authenticate or pre-pull images.
- **Storage bloat:** Always prune old containers before testing. Use `cleanup.maxAge` to control retention.
- **Firewall:** Rootless podman cannot modify iptables. Firewall rules must be declared via `firewallPorts` in the Nix module.

## Troubleshooting

### Stack fails to start

**Check podman-system-service:**
```bash
systemctl status podman-system-service
curl --unix-socket /run/user/1000/podman/podman.sock http://localhost/_ping
```

**Check logs:**
```bash
journalctl -u myapp-stack -f
```

**Check permissions:**
```bash
ls -la /mnt/docker/myapp/
```

### Permission denied errors

**Check volume ownership:**
```bash
ls -la /mnt/docker/myapp/
```

Should be owned by your user (uid 1000).

**For database containers, ensure `:U` flag:**
```yaml
volumes:
  - ${DATA_ROOT}/myapp/pgdata:/var/lib/postgresql/data:U
```

**For existing data from Docker, use root chown in preStart:**
```nix
preStart = [
  "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/myapp"
];
```

### Container can't access NFS mount

**Check mount is accessible to your user:**
```bash
ls -la /mnt/data/
```

**Never use `:U` flag on NFS mounts** - it will fail with "operation not permitted".

**If mount is slow (over Tailscale), use automount:**
```nix
dependsOn = ["mnt-data.automount"];  # Not .mount
# Don't include in requiresMounts
```

### Firewall blocking connections

**Check firewall status:**
```bash
sudo iptables -L -n | grep <port>
```

**Ensure ports are declared in docker-compose.nix:**
```nix
podman.mkService {
  # ...
  firewallPorts = [8080 8443];
}
```

**Verify firewall is enabled:**
```nix
# In host configuration.nix
networking.firewall.enable = true;
```

## Wishlist

### Per-Stack User Isolation

Currently all stacks run as the same homelab user (uid 1000) with shared access to `${DATA_ROOT}`. This has several limitations:

- **No isolation between stacks:** Any container can access any other stack's data
- **Broad blast radius:** A compromised container can affect all stacks
- **Coarse permissions:** Cannot apply per-stack quotas, resource limits, or access controls

**Desired state:**

- Each stack runs as its own dedicated user (e.g., `immich`, `paperless`, `jellyfin`)
- Each user has its own uid/subuid range for rootless podman
- Data directories isolated by user ownership
- XDG_RUNTIME_DIR per user (`/run/user/<stack-uid>`)
- Each stack can only access its own data and explicitly shared mounts

**Benefits:**

- Security isolation between stacks
- Per-stack resource accounting and limits
- Fine-grained access control to shared media
- Reduced blast radius for container escapes
- Easier to audit which stack accessed what

**Challenges:**

- Requires multiple podman system service instances (one per user)
- More complex secret management (per-user age keys)
- NFS/network mount permissions need group-based or ACL approach
- Increased systemd complexity (user@<uid>.service for each stack)
- Migration path for existing data ownership

**Implementation approach:**

1. Define stack users in NixOS config (via `users.users.<stack>`)
2. Assign unique uid ranges and subuid/subgid allocations
3. Run per-user podman-system-service instances
4. Update mkService to accept optional `serviceUser` parameter
5. Use systemd user units (`systemctl --user`) per stack user
6. Migrate data ownership incrementally with chown scripts
7. Use group `podman-stacks` for shared media access with ACLs

This would represent a significant architecture evolution but provide much stronger security boundaries between stacks.
