# NixOS Service Module Creation Rules

These rules apply when creating or modifying NixOS service modules under `modules/nixos/services/`.

## Service Hierarchy (in order of preference)

1. **Use the upstream nixpkgs module** if one exists (`services.<name>.enable = true`). Wrap it in a `homelab.services.<name>` module that wires in our infrastructure (proxy, monitoring, secrets, DB).
2. **Build a custom module** if the package exists in nixpkgs but has no module. Use `pkgs.<name>` and write a systemd service.
3. **Use podman/OCI containers** as a last resort. Use `virtualisation.oci-containers.containers` driven by `homelab.podman` (rootful, with autoupdate + autoheal). Multi-container services get split into per-container OCI entries plus a systemd unit to glue them together — the rootless `podman compose` stack system was retired on 2026-04-16 (see `docs/wiki/services/retired-container-stacks.md`).

`podman compose` / `docker-compose` is an anti-pattern in service modules. It
has repeatedly hidden lifecycle semantics from systemd and hung during stop
operations. Translate upstream compose files into explicit
`virtualisation.oci-containers` entries. If upstream only publishes Dockerfiles,
add a narrow image-build oneshot that runs `podman build` for those images; do
not put compose back into the steady-state runtime.

## Module Structure

Every service module lives at `modules/nixos/services/<name>.nix` and follows this pattern:

```nix
{ config, lib, pkgs, ... }: let
  cfg = config.homelab.services.<name>;
in {
  options.homelab.services.<name> = {
    enable = lib.mkEnableOption "<description>";
    dataDir = lib.mkOption { ... };  # if stateful
  };

  config = lib.mkIf cfg.enable {
    # 1. Service configuration (upstream module or custom)
    # 2. Database container (if needed)
    # 3. Systemd overrides (deps, restartTriggers)
    # 4. Secrets (sops)
    # 5. Infrastructure wiring (proxy, monitoring, NFS watchdog)
  };
}
```

After creating the module, add it to `modules/nixos/services/default.nix` imports list.

## Database Container Pattern (mk-pg-container)

When a service needs PostgreSQL, use an nspawn container for isolation and portability:

```nix
pgc = import ../lib/mk-pg-container.nix {
  inherit pkgs;
  name = "<service>";
  hostNum = <unique-number>;  # Check existing hostNums to avoid collisions
  inherit (cfg) dataDir;
  # REQUIRED: path to a sops-managed dotenv with POSTGRES_PASSWORD.
  # Prefer mode 0400 root:root; mk-pg-container copies the bindmount to
  # a private postgres-readable runtime file inside the nspawn.
  passwordFile = "/run/secrets/<service>-pgpass";
  # Optional: pgPackage, extensions, pgSettings, postStartSQL
};

# In config:
containers.<service>-db = pgc.containerConfig;

sops.secrets."<service>-pgpass" = {
  sopsFile = config.homelab.secrets.sopsFile "<service>-pgpass.env";
  format = "dotenv";
  mode = "0400";
};

services.<service>.database = {
  enable = false;  # Don't use system-wide PG
  host = pgc.dbHost;
  port = pgc.dbPort;
};
```

**Existing hostNums** (check before assigning):
- 1=atuin, 2=immich, 3=paperless, 4=mealie, 5=cratedigger, 6=discogs, 7=jellystat, 8=meelo, 9=youtarr

## Database Container Pattern (mk-mariadb-container)

When a service needs MariaDB/MySQL, use the MariaDB nspawn helper instead of a
shared host-level database:

```nix
mdbc = import ../lib/mk-mariadb-container.nix {
  inherit pkgs;
  name = "<service>";
  hostNum = <unique-number>; # Check existing hostNums to avoid collisions
  inherit (cfg) dataDir;
  # REQUIRED: path to a sops-managed dotenv with MYSQL_PASSWORD by default.
  passwordFile = "/run/secrets/<service>-db";
};

containers.<service>-db = mdbc.containerConfig;

sops.secrets."<service>-db" = {
  sopsFile = config.homelab.secrets.sopsFile "<service>-db.env";
  format = "dotenv";
  mode = "0400";
};
```

### MariaDB auth — no broad grants

`mk-mariadb-container` grants the service user access only to the service
database, only from the helper's host-side veth address. Do not add `%` grants,
TCP root access, or a shared host-level MariaDB instance unless there is a
separate threat-model writeup explaining why the blast radius is acceptable.

Local socket access inside the nspawn remains the ops path:
`sudo machinectl shell <name>-db`, then use the MariaDB client as the mysql user.
This mirrors the PostgreSQL helper's "local superuser, authenticated TCP
consumer" model without exposing fleet-wide database admin over podman.

### PG auth — never `trust` over TCP

**`mk-pg-container` requires `passwordFile`** and uses `scram-sha-256` for the
TCP rule. The host-side SOPS file should stay `0400 root:root` unless a service
consumer genuinely needs to read it directly; the helper copies it to a private
postgres-readable runtime file inside the nspawn before setup. `peer` auth on
the local Unix socket inside the container is the always-available superuser
backdoor — `sudo machinectl shell <name>-db` then `sudo -u postgres psql` for
schema work, password resets, etc.

**Never reintroduce `trust` over TCP.** It was retired on 2026-05-10 (see #232)
after empirical verification that any OCI container on `podman0` could pivot
to `postgres` superuser on every nspawn DB in the fleet — Linux IP forwarding
rewrites the source to `hostAddress`, which matched the `${hostAddress}/32 trust`
rule from outside the trust boundary.

**Wiring the password into the consumer.** The same sops secret feeds both
sides — `passwordFile` for the nspawn ALTER USER, plus the consumer reads
the same file (or a derivative). Three patterns by consumer shape:

1. **OCI containers** (jellystat): append the pgpass file to `environmentFiles`.
   Order matters — pgpass last so it wins on duplicate keys.

2. **nixpkgs services with a single env-file option** (immich, paperless, mealie):
   the upstream `secretsFile`/`environmentFile`/`credentialsFile` option still
   wires the consumer's main env file; layer the pgpass file via
   `systemd.services.<svc>.serviceConfig.EnvironmentFile = lib.mkAfter [...]`.
   For services where the consumer reads a non-canonical env var (e.g. Immich
   reads `DB_PASSWORD`, Paperless reads `PAPERLESS_DBPASSWORD`), include the
   alias in the pgpass.env file alongside `POSTGRES_PASSWORD`.

3. **Custom systemd services or DSN-as-CLI-arg modules** (atuin, cratedigger,
   discogs): EnvironmentFile loads `POSTGRES_PASSWORD` (and `PGPASSWORD` —
   the libpq standard, respected by sqlx, psycopg, and the postgres CLI).
   For services that need a full URI in their config, either:
   - Construct it in an `ExecStartPre` oneshot that writes a runtime env
     file (atuin pattern), or
   - Use a `writeShellScript` ExecStart wrapper that builds the DSN at
     runtime from `$POSTGRES_PASSWORD` (discogs pattern), or
   - Rely on `PGPASSWORD` being set in the unit env so libpq picks it up
     without the URI (cratedigger pattern).

**Out-of-band psql from the doc2 host** needs a credential lookup since the
operator account isn't auth'd by `peer`. One-liner:
`PGPASSWORD=$(sops -d secrets/hosts/<host>/<svc>-pgpass.env | grep ^POSTGRES_PASSWORD= | cut -d= -f2-) psql -h <ip> -U <name> -d <name>`.

### CRITICAL: restartTriggers for container dependencies

When a service uses `Requires=` on a DB container and it must be explicitly brought back after container reconfiguration, you MUST add `restartTriggers` to prevent cascade-stop orphaning. Without this, `switch-to-configuration` restarts the container (its config changed), systemd cascade-stops the dependent unit, but nobody brings it back.

```nix
systemd.services.<service> = {
  after = ["container@<service>-db.service"];
  requires = ["container@<service>-db.service"];
  restartTriggers = [config.systemd.units."container@<service>-db.service".unit];
};
```

This is primarily for long-running services and oneshot units whose active/completed state matters to dependents. Timer-driven oneshots that are expected to be inactive between runs usually do not need this.

**Pin the host-side unit derivation, NOT the inner container toplevel.** A previous iteration of this rule recommended `config.containers.<svc>-db.config.system.build.toplevel` — this is WRONG and caused a silent multi-service outage on 2026-04-13.

Why: `config.containers.<svc>-db.config.system.build.toplevel` is the NixOS system *inside* the container. But the container restart is driven by changes to its outer systemd unit wrapper (ExecStart/ExecReload scripts generated by nixpkgs under `unit-script-container_*-start`). Those wrappers are rebuilt whenever systemd-nspawn helpers change in nixpkgs, producing new store paths — which restarts the container — while the inner toplevel can remain byte-identical. Result: the `restartTriggers` hash doesn't change → switch-to-configuration skips restarting the app → `Requires=` cascade-stop leaves the app dead.

`config.systemd.units."container@<svc>-db.service".unit` is the host-side unit derivation and captures those wrapper script paths. It changes whenever anything about the container unit changes, which is what you actually want.

See `modules/nixos/lib/mk-pg-container.nix` header comment for the full pathology.

### Schema-ownership invariant — assert clean on every container start

`mk-pg-container` runs a final `RAISE EXCEPTION`-on-violation check against every
database in the instance: any table, view, materialized view, sequence, foreign
table or index in `public` whose owner is not the service role MUST appear in
the per-service `ownershipAllowList` or the container start fails (which fires
the existing `container@<svc>-db.service` Kuma monitor).

This exists because on 2026-05-20 we discovered Immich uploads had been silently
broken for 11+ days — `asset_edit_audit` had been recreated as `postgres`-owned
somewhere along the way, every monitor stayed green, and the only smoking gun
was buried in immich-server logs. The invariant catches the *next* such drift
on the next container restart (system rebuilds restart any nspawn whose unit
wrapper changes), turning a silent symptom into a loud container-down alert.
See issue #250 for the postmortem.

Scope is intentional: only "user data" object kinds (`r`,`v`,`m`,`S`,`f`,`i`).
Extension internals (functions, types, operators, opclasses) routinely live
under `postgres`; they aren't in scope and don't need to be listed. The audit
*trigger functions* Immich's migrations create as postgres are also out of
scope — they're stored in `pg_proc`, not `pg_class` — and need separate
investigation (likely upstream).

Populating the allow-list for a new service:

```nix
pgc = import ../lib/mk-pg-container.nix {
  # ... usual args ...
  ownershipAllowList = [
    # objects that are LEGITIMATELY owned by postgres (extension data tables,
    # geocoder imports loaded via COPY as superuser, etc.). List each by name
    # including supporting indexes/sequences explicitly.
    "geodata_places"
    "geodata_places_pkey"
    # ...
  ];
};
```

Empty list is the default and correct for every service except Immich today.
If a deploy fails with `schema-ownership invariant violated`, read the error
list and decide for each object: is it drift (run `ALTER ... OWNER TO <svc>`
to fix) or legitimate (add to the allow-list and re-deploy).

Operators can probe ownership state directly:

```sh
ssh <host> 'pid=$(sudo machinectl show <svc>-db -p Leader --value); \
  sudo nsenter -t $pid -m -p -u -i -n su -s /bin/sh postgres -c \
  "psql -d <db> -c \"SELECT relkind, relname, relowner::regrole FROM pg_class c \
  JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname='\''public'\'' AND \
  c.relowner::regrole::text <> '\''<svc>'\'';\""'
```

## DNS-First Networking

**All service-to-service URLs, scrape targets, and remote_write endpoints MUST use DNS names (FQDNs via `localProxy`, `tailscaleShare`, or Tailscale MagicDNS), never hardcoded LAN IPs.**

Hardcoded IPs break silently when hosts are renumbered, VMs are moved between hypervisors, or services migrate between hosts. The whole point of `localProxy` is that its Cloudflare A records follow the service — a move is a one-deploy change with zero consumer updates.

Concrete rules:

1. **Module code** (`modules/nixos/services/*.nix`): never embed `192.168.x.x` in option defaults, environment variables, or config templates. Use the service's FQDN option (e.g. `cfg.fqdn`, `https://${cfg.fqdn}`).
2. **Runtime config** (container env, application config files): same principle. If a container needs to reach another service, pass `https://<service>.ablz.au`, not a LAN IP.
3. **Exceptions**: nspawn-internal IPs (the `192.168.100.x` range from mk-pg-container) are derived from `hostNum` and don't represent fleet hosts — these are fine. pfSense's `remoteserver` field only accepts IPs (upstream limitation, documented in #208).
4. **Non-NixOS devices** (tower/Unraid, pfSense): if the device has no FQDN managed by `localProxy`, document the IP usage and why a DNS name isn't viable. Prefer setting up a FQDN when possible.

## Infrastructure Wiring

Every service should wire into these infrastructure systems where applicable:

### Reverse Proxy (DNS + SSL + nginx)

```nix
homelab.localProxy.hosts = [{
  host = "<service>.ablz.au";
  port = <port>;
  websocket = true;     # optional, for websocket support
  maxBodySize = "0";    # optional, for large uploads
}];
```

This automatically creates nginx virtualHosts with ACME certs and syncs DNS to Cloudflare.

### Monitoring (Uptime Kuma)

```nix
homelab.monitoring.monitors = [{
  name = "<Service Name>";
  url = "https://<service>.ablz.au/health";  # or /api/ping, etc.
}];
```

**Noise discipline.** The monitor submodule has tuned defaults to keep Gotify
signal-to-noise high — do NOT override these unless you have a concrete reason:

- `interval = 60` — check cadence in seconds
- `maxretries = 10` — consecutive failures before DOWN; with the 60s interval,
  a monitor needs ~10 minutes of continuous failure before it pages. This
  suppresses every transient blip from nightly rebuilds, container restarts,
  and NFS hiccups.
- `retryInterval = 60` — seconds between retries
- `resendInterval = 240` — heartbeats between re-notifications while still
  DOWN; at interval=60s, ≈4h. Ensures a persistent outage re-pages so you
  notice if you missed the first alert.

If you bump `interval` on a monitor, remember `resendInterval` is measured
in heartbeats, not minutes — recompute it so the re-page cadence stays ~4h.

**Maintenance windows.** Fleet-wide noise windows (e.g. the nightly auto-update
window) live on the host running Uptime Kuma — see
`modules/nixos/services/uptime-kuma.nix`. Declare each window exactly once,
on that host, to avoid cross-host sync races. The sync service creates and
updates windows declaratively via
`homelab.monitoring.maintenanceWindows = [{ title; startTime; endTime; ... }]`.
By default a window applies to every monitor in Kuma
(`appliesToAllMonitors = true`).

Do NOT add a new maintenance window for a one-off service restart — bump the
service's `maxretries` instead, or just accept the alert.

### NFS Watchdog (for NFS-dependent services)

```nix
homelab.nfsWatchdog.<service-name>.path = "/mnt/data/...";
```

Creates a timer that checks the NFS path every 5min and restarts the service if the mount is stale.

### Secrets (sops-nix)

```nix
sops.secrets."<service>/env" = {
  sopsFile = config.homelab.secrets.sopsFile "<service>.env";
  format = "dotenv";
  owner = "<service-user>";
  mode = "0400";
};
```

The `sopsFile` helper searches: `secrets/hosts/<hostname>/` -> `secrets/users/<user>/` -> `secrets/`.

## Host Assignment

Services are enabled in host configs (`hosts/<host>/configuration.nix`):

```nix
homelab.services.<name> = {
  enable = true;
  dataDir = "/mnt/virtio/<name>";  # virtiofs mount for portability
};
```

The module design must allow the service to run on ANY host by changing only the host config. All paths, ports, and dependencies should be configurable via options.

## VPN Routing (for services needing external VPN)

See `slskd.nix` for the dual-NIC policy routing pattern. Services needing VPN use a second NIC with UID-based routing rules that send traffic through pfSense's WireGuard tunnel.

## Podman/OCI Services

For services that must use containers:

```nix
homelab.podman = {
  enable = true;
  containers = [{
    unit = "podman-<name>.service";
    image = "<registry>/<image>:<tag>";
  }];
};

virtualisation.oci-containers.containers.<name> = {
  image = "...";
  autoStart = true;
  ports = ["<host-port>:<container-port>"];
  volumes = ["<dataDir>:/data"];
  environmentFiles = [config.sops.secrets."<name>/env".path];
};
```

## External Sharing (tailscaleShare)

Use `homelab.tailscaleShare` when a service needs to be accessible from **outside your tailnet** — e.g. sharing with someone on a different tailscale account. This is distinct from `localProxy` (LAN-only) and from the main doc2 tailscale node (which shares the whole VM).

**Principle: one pinhole per application.** Each instance gets its own dedicated tailscale node identity and IP. Only that service is reachable — not the host, not other services.

### When to use which

| Pattern | DNS points to | Reachable from |
|---|---|---|
| `localProxy` | Doc2 LAN IP (192.168.1.35) | Your LAN only |
| `tailscaleShare` | Sidecar tailscale IP (100.x.x.x) | Any tailnet (inter-tailnet) |

A service can use both simultaneously — one FQDN for LAN access, another for inter-tailnet sharing (e.g. `request.ablz.au` + `overseer.ablz.au`).

### Module signature

```nix
homelab.tailscaleShare.<name> = {
  enable      = true;
  fqdn        = "overseer.ablz.au";              # Cloudflare A record → tailscale IP
  upstream    = "http://host.docker.internal:5055"; # NEVER use 127.0.0.1 — see below
  dataDir     = "/mnt/virtio/overseerr/ts";       # tailscale state + caddy certs
  hostname    = "overseer";                       # tailscale node name (default: attrset key)
  firewallPorts = [5055];                         # ports to open on podman0 bridge
  monitorName = "Overseerr (Tailnet)";             # optional friendly Kuma name
  monitorPath = "/api/v1/status";                  # optional health endpoint, default "/"
};
```

### What gets provisioned per instance

- `ts-<name>` OCI container — tailscale, joins tailnet with dedicated identity, persists state to `dataDir/ts-state/`
- `caddy-<name>` OCI container — caddy-cloudflare image, shares ts's network namespace, handles HTTPS + ACME via Cloudflare DNS challenge, certs in `dataDir/caddy-data/`. Its Caddy admin API is disabled because the shared loopback is reachable from `ts-<name>`.
- `tailscale-share-dns-sync-<name>` systemd oneshot — waits for tailscale online, upserts Cloudflare A record pointing `fqdn` → tailscale IP
- `homelab.monitoring.monitors` entry — Uptime Kuma checks the tailscale-served HTTPS URL itself, not just the LAN/localProxy URL
- sops secret `tailscale-share/<name>/authkey` — sourced from `secrets/hosts/<hostname>/<name>-tailscale-authkey.env`
  unless `authKeySecret = null`, which uses Tailscale's interactive first-run login URL and persists the resulting node state.

### Secret

Create the auth key secret as a dotenv file (`.env` extension required — sops detects format by extension):

```
secrets/hosts/<hostname>/<name>-tailscale-authkey.env
```

Content: `TS_AUTHKEY=tskey-auth-<key>`. Generate a reusable auth key in the Tailscale admin panel.

### Critical networking gotchas

**1. Never use `127.0.0.1` as the upstream.**
The caddy container shares the tailscale container's network namespace. `127.0.0.1` is the *container's* loopback — the host is not there. Use `http://host.docker.internal:<port>` instead.

**2. `--add-host` goes on the ts container, not caddy.**
Containers joining another container's network namespace (`--network=container:ts-<name>`) cannot set `--add-host` — Podman rejects it. The joining container inherits `/etc/hosts` from the namespace owner (ts). Set `--add-host=host.docker.internal:host-gateway` on the ts container; caddy picks it up automatically.

**3. NixOS firewall blocks container→host by default.**
Use `firewallPorts` to open the upstream service's port on the `podman0` bridge interface. Without this, caddy gets a 502 even though `host.docker.internal` resolves correctly.

**4. Shared loopback is shared control-plane surface.**
Caddy does not inherit `NET_ADMIN` from the tailscale sidecar, but both
containers share one network namespace. Anything Caddy exposes on
`127.0.0.1` is reachable from `ts-<name>`. Keep `admin off` in the generated
Caddyfile and verify from the tailscale sidecar after deploy.

### Checklist additions for tailscaleShare

- [ ] Secret file named `<name>-tailscale-authkey.env` (with `.env` extension) in `secrets/hosts/<hostname>/`
  or `authKeySecret = null` with the first-run login URL captured from `podman-ts-<name>.service`
- [ ] `upstream` uses `http://host.docker.internal:<port>`, not `127.0.0.1`
- [ ] `firewallPorts` set to the upstream service's port
- [ ] `dataDir` subdirs (`ts-state/`, `caddy-data/`, `caddy-config/`) survive any rsync operations (use `--exclude ts/` or similar if rsyncing the parent)
- [ ] Caddy admin endpoint stays disabled; `ts-<name>` cannot fetch `127.0.0.1:2019/config/`
- [ ] Caddy runs as the dedicated `tailscale-share-caddy` user with `NoNewPrivs=1`, default capabilities dropped, and only `NET_BIND_SERVICE` added back for 80/443
- [ ] Tailscale auth/state and Caddy Cloudflare/cert state remain separate in env and mounts
- [ ] `dataDir` is under a root-owned parent, not inside an upstream service-owned app data directory
- [ ] Kuma monitor exists for the tailscale-served URL; set `monitorPath` to the app health endpoint when one exists

## Anti-Patterns (avoid)

Concrete failure modes we've hit. Add to this list when you find a new one.

### Auth & secrets

- **`host all all <addr>/32 trust` in pg_hba.** Caused fleet-wide superuser
  pivot from any OCI container (#232, 2026-05-10). `mk-pg-container` enforces
  `scram-sha-256` with `passwordFile` now — don't relax it.
- **DB password embedded in a Nix-eval string** (e.g. `pipelineDb.dsn =
  "postgresql://user:${pwdLiteral}@..."`). Leaks to `/nix/store`. Construct
  DSNs at runtime from EnvironmentFile-loaded vars instead.
- **Hardcoded passwords in container env attrsets.** `environment.POSTGRES_PASSWORD = "abc"`
  is plaintext in /nix/store and the systemd unit. Use `environmentFiles =
  [config.sops.secrets...path]` instead.
- **Decrypting a multi-secret env file at mode 0444 just to share one field
  with another consumer.** Splits the trust boundary for every other secret
  in the file. Put the shared field in its own `<svc>-pgpass.env` (or similar
  narrow file) at 0400; keep the wider env file at 0400. `mk-pg-container`
  copies root-only pgpass files to a private postgres-readable runtime file
  inside the nspawn container, so host-side pgpass files do not need to be
  world-readable.

### Privilege & isolation

- **OCI container running as UID 0** with rw bind mounts to shared host paths
  (`/mnt/data/Media`, `/mnt/mirrors`). A compromised container can encrypt or
  delete adjacent services' data. Pin a non-root UID via `--user=<uid>:<gid>`
  in `extraOptions` (see jellystat for the pattern).
- **`pull = "newer"` on `:latest`/`:master` tags.** Nightly auto-update can
  silently swap the image — including supply-chain compromises in upstream's
  Docker Hub or GitHub. Pin to digests (`@sha256:...`) for any service whose
  upstream isn't ours.
- **Shared network namespace without shared-loopback audit.** Capabilities are
  per-container, so caddy does not inherit tailscale's `NET_ADMIN`; the real
  failure mode is control-plane exposure over shared `127.0.0.1` plus a broad
  caddy runtime. Disable local admin/control endpoints, drop capabilities on
  the joining container, and verify from both containers.

### Network exposure

- **`listen 0.0.0.0` when only LAN access is wanted.** Every consumer should
  bind `127.0.0.1` and surface via `homelab.localProxy.hosts`. Binding to all
  interfaces gives any LAN segment direct unauthenticated access — no nginx
  rate-limit, no ACL, nothing.
- **Services on the default `podman` bridge that don't need to talk to each
  other.** Default-network membership lets every container L3-reach every
  other on `10.88.0.0/16`. Per-service podman networks are cheap and bound the
  pivot surface.

### Image trust

- **Personal Dockerhub repos** (`docker.io/<personal-handle>/...`) without
  digest pinning. Single-author trust chain, no signing. Always pin to
  `@sha256:...`. If the project is unmaintained, vendor the image into
  `pkgs.dockerTools` instead.
- **Tracking upstream `master` of a `flake = false` input that builds an
  image we run** (`musicbrainz-docker` learned this on 2026-05-10 when the
  PG16→PG18 bump broke our cluster — #228, #229). Pin those inputs explicitly
  and bump them by hand.

### Mount ordering

- **`fileSystems` bind/overlay/fuse entries whose source path lives on a
  network filesystem (NFS, CIFS, sshfs, …) that lack `_netdev`.**
  systemd-fstab-generator places non-`_netdev` mounts in `local-fs.target`,
  which is ordered *before* `network-online.target`. When such a unit also
  declares `After=mnt-data.mount` (or any other network-backed mount), it
  closes an ordering cycle: `local-fs.target → bind.mount → mnt-data.mount
  → network-online.target → … → local-fs.target`. systemd resolves the
  cycle by deleting a start job at random — on 2026-05-13 this took out
  `network-online.target/start` twice, causing gatus and webdav (and a
  failed `multi-user.target`) on a doc2 boot. The fix is `_netdev` (places
  the unit in `remote-fs.target` instead, breaking the cycle) plus `nofail`
  for resilience. See `docs/wiki/infrastructure/systemd-mount-ordering-cycles.md`.
- **`fileSystems` mountpoints containing literal spaces.** Nix writes spaces
  to fstab as `\040`, but switch-to-configuration-ng currently derives mount
  unit names from the still-escaped fstab field and asks systemd for
  `\x5c040` instead of `\x20` (#247). If a service path must live under a
  human-named NFS directory, expose a space-free runtime path (usually a
  symlink under `/var/lib/<service>-...`) and point the service at that.

## Checklist

Before submitting a new service module:

- [ ] Options under `homelab.services.<name>` with `enable` and `dataDir`
- [ ] Added to `modules/nixos/services/default.nix` imports
- [ ] If using DB container: `restartTriggers` on app service referencing container toplevel
- [ ] If using `mk-pg-container`: `passwordFile` set to a 0400 sops dotenv with
      `POSTGRES_PASSWORD`, consumer wired to load same file (see PG auth section)
- [ ] If using `mk-pg-container`: any postgres-owned objects in `public` are
      declared in `ownershipAllowList`; deploy fails loudly otherwise (see
      Schema-ownership invariant section)
- [ ] OCI containers run with `--user=<non-root-uid>:<gid>` in `extraOptions`
- [ ] Image refs pinned to digests for any non-nixpkgs upstream
- [ ] App listens on `127.0.0.1`, exposed via `homelab.localProxy.hosts`
- [ ] `homelab.localProxy.hosts` entry for DNS/SSL/nginx
- [ ] `homelab.monitoring.monitors` entry for health checking
- [ ] `homelab.nfsWatchdog` if service depends on NFS paths
- [ ] Secrets via `sops.secrets` + `config.homelab.secrets.sopsFile`
- [ ] No hardcoded LAN IPs in module code or runtime config (see DNS-First Networking above)
- [ ] No hardcoded passwords in `environment` attrsets — use `environmentFiles`
- [ ] Any `fileSystems` entry whose source lives on a network filesystem
      carries `_netdev` (and ideally `nofail`); see Mount ordering anti-pattern
- [ ] No `fileSystems` mountpoint contains literal spaces; use space-free
      service-facing paths instead
- [ ] Service enabled in appropriate host config
- [ ] `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` succeeds
