# Container Stacks

Rootless Podman container stack definitions for the homelab.

IMPORTANT: keep as much state as possible in each stack's own `docker-compose.nix` (service file). Avoid centralizing stack-specific details elsewhere.

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
  - `stackHosts` → per-host local proxy + DNS registration (optional, create/update/remove managed A records)
  - `stackMonitors` → Uptime Kuma monitor registration (optional; portable domain-based checks)
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

    stackHosts = [  # Optional: local proxy + DNS registration (local IP, TTL 60s)
      {
        host = "myapp.ablz.au";
        port = 8080;
        # websocket = true; # Optional: only when the app needs websockets (e.g., Uptime Kuma)
      }
    ];

    stackMonitors = [  # Optional: Uptime Kuma monitoring
      {
        name = "MyApp";
        url = "https://myapp.ablz.au/";
      }
    ];

    # Targeted monitoring (when the root path isn't a good health check)
    # Example: Plex returns 401 on "/" when unauthenticated, but "/identity" is a 200 OK health endpoint.
    # Use the most reliable endpoint for the service rather than accepting 401.

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

### Targeted Monitoring

Some services return 401 on `/` when unauthenticated (e.g., Plex). For those, use a health endpoint that returns 200 instead of loosening accepted status codes. Example: Plex supports `/identity` as a reliable 200 OK health check.

### Monitoring Automation Notes

- Monitors are declared per-stack via `stackMonitors` and synced by `homelab-monitoring-sync.service`.
- Default notification targets in Uptime Kuma are applied automatically to all managed monitors.
- Local cache: `/var/lib/homelab/monitoring/records.json` (per-host).
- Secrets:
  - `secrets/uptime-kuma.env` (KUMA_USERNAME / KUMA_PASSWORD)
  - `secrets/uptime-kuma-api.env` (KUMA_API_KEY for metrics)

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

    stackHosts = [
      {
        host = "mynewapp.ablz.au";
        port = 8080;
      }
    ];

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

## Critical Gotchas

### Service Lifecycle: stop vs down

**This is the most important gotcha for Dozzle compatibility.**

Podman's container events differ from Docker's. When using `podman-compose down`, containers are removed and recreated with new IDs. Dozzle tracks containers by ID, so this causes:
- Ghost containers (old IDs shown as stopped)
- Lost log streams (new container, different ID)

**Solution:** Use `stop` instead of `down` in ExecStop:
```nix
ExecStop = "podman-compose stop";   # Preserves container ID
ExecStart = "podman-compose up -d"; # Reuses stopped container
```

The `up -d` command is smart enough to start existing stopped containers without recreating them.

### Migration Chown: One-Time Only

**Do NOT run `podman unshare chown` on every service start.**

When migrating from Docker to rootless Podman, you need to fix ownership once. But:
- Running it every start wastes time
- It fails if containers created files with restrictive permissions (e.g., postgres data)
- Jellyfin stack was failing because postgres directories blocked recursive chown

**Correct pattern:**
```nix
preStart = [
  # Just ensure directories exist - don't chown existing data
  "/run/current-system/sw/bin/mkdir -p ${dataRoot}/myapp/data"
];
```

For initial migration, run chown manually once:
```bash
sudo chown -R 1000:1000 /mnt/docker/myapp
```

### System Services Need CONTAINER_HOST

System services (`/etc/systemd/system/`) running as `User=abl030` cannot see rootless containers without explicitly connecting to the user's podman socket.

**Required in service environment:**
```nix
Environment = [
  "CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock"
];
```

Without this, `systemctl restart mystack` silently fails to find containers.

### Dozzle Agent Needs Persistent engine-id

Podman doesn't create `/var/lib/docker/engine-id` like Docker does. Dozzle uses this file to identify hosts. Without it, the agent generates a new UUID on every restart, causing the Dozzle server to lose track.

**Fix:** Create and mount a persistent engine-id:
```yaml
volumes:
  - ${DATA_ROOT}/dozzle-agent/docker/engine-id:/var/lib/docker/engine-id:ro
```

Create the file once:
```bash
mkdir -p /mnt/docker/dozzle-agent/docker
uuidgen > /mnt/docker/dozzle-agent/docker/engine-id
```

## Other Gotchas

### NixOS Module Integration

- **Avoid naming conflicts:** Don't name systemd services/timers that conflict with nixpkgs (e.g., use `podman-rootless-prune` not `podman-prune`).
- **Shallow merge (`//`) overwrites:** Use `lib.mkMerge` instead of `//` when combining `mkService` with custom config.

### Permissions & Ownership

- **Database containers require `:U`:** Postgres/MariaDB run as uid 999 internally → host uid 100999. Without `:U`, container can't access host uid 1000 files.
- **Never use `:U` on NFS:** Fails with "operation not permitted".
- **LSIO images:** Use `PUID=0` which maps to host uid 1000 in rootless.
- **Existing root-owned dirs block podman unshare:** Use root chown in preStart instead.

### Systemd & Mounts

- **RequiresMountsFor creates hard dependencies:** Service fails if mount times out. Use `automount` for slow/optional mounts.
- **bindsTo for coordinated restarts:** Ensures stacks restart when podman-system-service restarts.
- **Dependency failures don't trigger Restart:** Use `bindsTo` instead of relying on `Restart=on-failure`.

### Compose & Containers

- **podman-compose dependency handling is strict:** Add healthchecks to database containers.
- **Network holder pattern:** Use pause container as network holder for multi-container stacks.

### Operations

- **Docker Hub rate limits:** Pre-pull or authenticate.
- **Firewall:** Rootless podman can't modify iptables. Use `firewallPorts` in Nix module.

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

**Check kernel logs for refused connections:**
```bash
journalctl -k --no-pager -n 30 | grep -i "refused"
```

**Ensure ports are declared in docker-compose.nix:**
```nix
podman.mkService {
  # ...
  firewallPorts = [8080 8443];
}
```

**For IP-filtered firewall rules**, use `lib.mkMerge` to combine `mkService` with custom firewall rules (don't use `//` - it causes shallow merge issues):
```nix
lib.mkMerge [
  (podman.mkService {
    inherit stackName;
    # ... other params, but NOT firewallPorts
  })
  {
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p tcp -s 192.168.1.29 --dport 7007 -j nixos-fw-accept
    '';
  }
]
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
# Local Proxy + DNS (per-host)

Each host runs a single nginx instance (via `homelab.nginx`) that reverse-proxies
all stacks on that host. Stacks opt in by declaring `stackHosts` with hostname + port.

**What it does:**
- Creates nginx vhosts for each `stackHosts` entry.
- Requests ACME certs via Cloudflare DNS-01.
- Updates Cloudflare DNS A record to the host local IP.
- HTTP → HTTPS redirect is enforced at nginx.

**Host setup:**
Add `localIp = "192.168.x.y";` in `hosts.nix`.

**DNS sync:**
Stateful sync runs on rebuild and stores cache in `/var/lib/homelab/dns/`.
Check API call count at `/var/lib/homelab/dns/api-call-count`.

**ACME propagation note:**
If a new cert fails with `NXDOMAIN` or `incorrect TXT`, a stale TXT record may exist.
Clear `_acme-challenge.<host>` TXT records and re-run the `acme-order-renew-<host>` unit.
