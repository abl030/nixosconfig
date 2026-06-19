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

### DB audit logging — always on, alerted on non-startup superuser DDL

`mk-pg-container` ships every nspawn PG instance with:

```
log_statement      = 'ddl'   -- every CREATE/ALTER/DROP/etc.
log_connections    = on      -- every auth attempt
log_disconnections = on      -- every session end
log_line_prefix    = '%m [%p] %u@%d/%a from %h: '
```

DDL on a steady-state DB is rare, so volume is low. Connection logs add a few hundred lines per day per DB at most. All journal output ships through alloy → Loki under `unit=container@<svc>-db.service`.

`mk-mariadb-container` has the equivalent: `server_audit` plugin loaded with `server_audit_events = 'CONNECT,QUERY_DDL'`, syslog output, excluding `root@localhost,mysql@localhost` (local-socket ops backdoor stays silent so the alert layer only sees external TCP sessions).

#### `mk-pg-container-startup` — the tag for our own boot-time DDL

Both helpers' postStart scripts run CREATE EXTENSION / ALTER EXTENSION UPDATE / ALTER SCHEMA OWNER / etc. on every container start. These are DDL as the `postgres` superuser and would flood the alert below. We tag them via:

```nix
systemd.services.postgresql-setup.environment.PGAPPNAME = "mk-pg-container-startup";
```

The Loki alert excludes lines containing that string. If you add another psql invocation to `mk-pg-container.nix` (or similar) make sure it inherits the environment, or set `PGAPPNAME` explicitly on its `serviceConfig.Environment`.

#### Alert: `homelab-pg-superuser-ddl`

LogQL (lives in `modules/nixos/services/alerting.nix`):

```
sum(count_over_time(
  {host=~".+", unit=~"container@.+-db\\.service"}
  |~ "postgres@[^ ]+ from .+ LOG: +statement: (?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)"
  !~ "mk-pg-container-startup"
  [5m]
)) > 0
```

Fires on any postgres-role DDL outside our tagged startup. That covers two legitimate cases (operator shell sessions, restore scripts) and one drift case (silent superuser rewrite, like #250). All three deserve a glance — the alert annotation includes a Grafana Explore query to find the offending line in Loki.

#### Alert: `homelab-mariadb-audit-ddl`

LogQL:

```
sum(count_over_time(
  {host=~".+", unit=~"container@.+-db\\.service"}
  |~ ",QUERY,.*,'(?i)(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE) "
  [5m]
)) > 0
```

`server_audit` syslog format includes `,QUERY,<db>,'<sql>',<errno>` — we match on `QUERY` events containing DDL keywords. The plugin's `server_audit_excl_users` already filters out local-socket root/mysql; anything that gets logged here is by definition a TCP session as a non-excluded user, which is alarmworthy by default.

#### Investigating an alert

Open Grafana Explore on the Loki datasource, paste the LogQL from the alert's annotation. The line includes `<user>@<db>/<application_name> from <client_host>: LOG:  statement: <SQL>` (PG) or `,<user>@<host>,...,QUERY,<db>,'<SQL>',<errno>` (MariaDB). PID + timestamp let you cross-reference with `log_connections` lines to find the connect/disconnect window of the session.

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

`mk-pg-container` also promotes `postgresql-setup.service` from
`WantedBy=multi-user.target` to `RequiredBy=multi-user.target` so a failed
invariant (or any other failed startup step) propagates outward: inner
`multi-user.target` doesn't reach, the nspawn notify-ready times out, and
the outer `container@<svc>-db.service` goes red — which the existing Kuma
monitor on that unit catches automatically. Without this promotion the
inner failure is journal-only and Kuma stays green.

Scope is intentional: only "user data" object kinds (`r`,`v`,`m`,`S`,`f`,`i`).
Extension internals (functions, types, operators, opclasses) routinely live
under `postgres`; they aren't in scope and don't need to be listed. The audit
*trigger functions* Immich's migrations create as postgres are also out of
scope — they're stored in `pg_proc`, not `pg_class` — and need separate
investigation (likely upstream).

**Grant-presence assertion** (added 2026-05-20 after the geodata_places
incident). Allow-listed objects are not owned by the service role, so the
service role has zero implicit privileges on them. The invariant therefore
runs a second `DO` block that asserts `has_table_privilege` /
`has_sequence_privilege` `SELECT` for the service role on every relation/
sequence whose name is in `ownershipAllowList`. Indexes are skipped (grants
inherit from the table).

Triggered by today's silent failure: Immich's reverse-geocoder tables
(`geodata_places`, `naturalearth_countries`) had been postgres-owned with
no `GRANT SELECT` to `immich` for 10+ days. Every photo upload's
`AssetExtractMetadata` job failed silently — the new errorPattern alert
caught it on the first fresh upload. Now the deploy would refuse to come
up if a service module declares an allow-list entry without the
corresponding grant in `postStartSQL`.

Pair this with `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
GRANT SELECT ON TABLES TO <service>` in `postStartSQL` so any future
postgres-created table inherits SELECT automatically — that handles the
extension-or-microservice creates-new-postgres-owned-table case at the
source.

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

#### Moving a `localProxy` service between hosts — deploy NEW host first

Each host runs its own `homelab-dns-sync` over the union of its enabled
services' `localProxy.hosts`. When a service migrates, both hosts briefly claim
the same FQDN. Cloudflare A records carry an ownership tag
(`comment = "managed-by:<hostname>"`); cleanup only deletes records that are
unclaimed or owned by the running host, so one host can never delete a record
another has claimed (this is the fix for the #202 race — see
[`services/local-proxy-dns-sync.md`](services/local-proxy-dns-sync.md)).

Operational rules when moving a service:

1. **Deploy the destination (new) host first, then the source (old) host.** The
   new host's `PUT` takes over the record in place (zero downtime) and stamps
   its tag; the old host's cleanup then sees the new owner and leaves it alone.
   Old-host-first works too but deletes-then-recreates → a brief wildcard 502
   window.
2. **Deploy both hosts in the same maintenance window.** Until the old host is
   redeployed its running closure still lists the FQDN, and its nightly
   `homelab-dns-validate` (02:00) can re-claim the record. Don't leave a fleet
   half-migrated overnight.
3. **Never commit the same FQDN on two hosts permanently** — that flip-flops the
   A record every deploy. A service lives on exactly one host at a time.

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

### Deep write-path probes (stateful services)

Shallow HTTP healthchecks (`/api/server/ping` returns 200) only confirm "the process is up." They don't exercise the database write path, the disk layer, or the actual user-visible feature. The 2026-05-20 `asset_edit_audit` incident (#250) is the canonical failure: uploads were 100% broken for 11+ days while every shallow Kuma monitor stayed green.

**Every stateful service module MUST declare a `homelab.monitoring.deepProbes` entry** unless the failure modes are genuinely covered by the shallow monitor (the bar for that opt-out is high — document the reasoning inline).

```nix
homelab.monitoring.deepProbes = [
  {
    name = "<Service> write-path";
    command = "${pkgs.callPackage ./probes/check-<service>.nix {}}/bin/check-<service>";
    interval = "5m";          # systemd OnUnitActiveSec
    intervalSecs = 300;       # Kuma's heartbeat-expected interval
    serviceConfig = {
      Environment = [
        "FOO_API_KEY_FILE=${config.sops.secrets."<svc>-monitor/api-key".path}"
      ];
    };
  }
];
```

**Per-probe machinery (auto-generated by `homelab.monitoring.deepProbes`):**

1. A Kuma push monitor with `type=push`, named exactly as `name`. Kuma issues a unique `pushToken` on first creation; the `monitoring_sync` python script reads it back and writes the push URL to `/var/lib/homelab/monitoring/push-urls/<slug>.url`.
2. A systemd timer `deep-probe-<slug>.timer` (interval `interval`, AccuracySec 10s).
3. A systemd oneshot `deep-probe-<slug>.service` (TimeoutStartSec `timeout`). The oneshot runs the probe command; on exit 0 it curls the push URL with `status=up&ping=<ms>`. On any non-zero exit OR timeout it does NOT push — Kuma misses heartbeats and flips DOWN after `maxretries` (default 2).

**Probe script conventions:**

- Lives in `modules/nixos/services/probes/check-<service>.nix` as a `writeShellApplication`.
- Reads secrets from `<SERVICE>_API_KEY_FILE`, not from `EnvironmentFile` directly — survives systemd hardening.
- Exits 0 on healthy, non-zero on any failure. Distinguish auth (4xx) from server error (5xx) in the log message so operators can triage without re-running.
- Uses `curl -sS -o /dev/null -w '%{http_code}'` rather than `-f` so we can branch on status. `-f` fails on >=400 without giving us the status code.
- Picks the probe target most likely to catch the failure class. For Immich that's a direct SQL `SELECT 1 FROM asset_edit_audit LIMIT 1` as the immich role over the nspawn veth — the exact failure mode from #250. We initially tried POSTing to `/api/sync/stream` but Immich rejects API-key auth on sync endpoints (`"Sync endpoints cannot be used with API keys"`). Direct SQL is tighter anyway: no API key to rotate, no API surface drift across Immich versions, no auth dance.

**HTTP probe vs SQL probe.** For services where the failure mode is "the app can't talk to its DB" (most stateful services), an HTTP probe through an auth'd endpoint is good. For services where the failure is specifically a permission/schema state we know how to assert directly (the #250 class), a SQL probe is more surgical — and avoids the "API endpoint we needed got renamed" tax. Pick per service.

**Where to look when a probe goes red:**

- `journalctl -u deep-probe-<slug>.service -n 50` — probe stdout/stderr (the script's diagnostic messages).
- Kuma UI heartbeat history → last-good timestamp shows when it last passed.
- `/var/lib/homelab/monitoring/push-urls/<slug>.url` — confirm the file exists and is the right Kuma URL (sometimes monitor_sync hasn't caught up yet on a fresh deploy).

### Per-service `errorPatterns` (log-line alert rules)

Shallow HTTP healthchecks and deep probes catch their own failure classes (process up / write path healthy). Neither catches the third class: **the service is up, the DB is fine, but the app itself is logging that something is broken** — failed migrations, hung queues, queue dispatcher exceptions, machine-learning model load failures. The 2026-05-20 `asset_edit_audit` incident (#250) lived in this class for 11 days — Immich's logs screamed `PostgresError: permission denied for table asset_edit_audit` while every monitor stayed green.

`homelab.monitoring.errorPatterns` closes that gap. Each entry compiles into a Grafana Loki alert rule scoped to a (host, unit, optional container) tuple plus a regex. Fires when the pattern matches inside a sliding window (default 5m), routes through the alert-bridge for a claude-summarised Gotify push.

```nix
homelab.monitoring.errorPatterns = [
  {
    name = "Immich DB write failure";
    unit = "immich-server.service";
    pattern = "PostgresError|permission denied for table|migration failed";
    severity = "critical";
    summary = "Immich app is throwing DB errors — uploads likely broken";
    description = ''
      Likely class of failure: schema-permission drift like #250, or a
      failed migration that didn't roll back. Cross-reference the
      schema-ownership invariant from mk-pg-container.nix and the
      kysely_migrations table inside immich-db.
    '';
    # Single-shot terminal pattern — page on first occurrence.
    threshold = 0;
  }
];
```

**Quiet-by-construction.** Only patterns you opt into can alert. Don't catch generic `error` or `failed` — that's noise from systemd unit cleanup, k8s probe failures, and routine log chatter. Catch the SPECIFIC strings the service emits when actually broken. The #253 audit produced per-service fingerprints by reading 30 days of Loki history; replicate that methodology if you add a new service.

**Threshold — sustained vs single-shot (the "glide out of a reboot" rule):**

Default `threshold = 2` (since 2026-05-23 — issue #281). Meaning: `count > 2`, i.e. needs **3+ matches in the 5min window** before the alert fires. This absorbs the 1-2 transient log lines a service emits on the way down during a planned reboot (alloy can't push, aardvark-dns can't start a transient scope, anything-logs-on-shutdown), so a doc2 reboot doesn't generate a fleet-wide alert burst. Real sustained failures still fire within ~6 min.

Decide per pattern:

| Pattern shape | `threshold` | Why |
|---|---|---|
| Service crash / `panic` / `FATAL` / `UnhandledPromiseRejection` | `0` | Process dies after one log line; default would silently lose the alert. |
| `Failed at step NAMESPACE` / start failure | `0` | systemd `StartLimitBurst` caps retries; can't rely on 3+ occurrences. |
| Backup hook failure (`pg_dump non-zero`, `Database Backup Failure`, kopia `despite N retries`) | `0` | Backup unit logs the give-up line once then exits. By the time it lands, the failure already represents many internal retries. |
| Migration failed / `relation does not exist` | `0` | Migration unit exits on first failure. |
| Watchdog tripped (`is stale, restarting`) | `0` | Watchdog only logs once per cycle (e.g. 5min); waiting for 3 cycles = ~15min lag. |
| DB connection failure during sustained outage | default (`2`) | Repeats on every connection attempt — accumulates quickly. |
| Replication/network-style transient (e.g. Solr proxy 500s while peer reconnects) | `3` or higher | Routinely emits ~30s of matching lines during normal restart cascades; need to distinguish from real partial-outage. |
| Auth-loss style ("control: 401" every poll) | default (`2`) | Real auth loss repeats every poll; benign boot-time one-off filtered. |

**Catalogue of current `threshold = 0` overrides** (search `threshold = 0` in `modules/nixos/services/` to find them): kopia (all 4 patterns), gotify-server, uptime-kuma, musicbrainz post-deploy, nfs-watchdog, paperless (all 4 patterns), pfsense-backup-watchdog, cratedigger (both patterns), immich.

**Don't blindly add `threshold = 0`.** If the failure mode is "repeats while broken" (DB connection failures, push-batch drops, podman aardvark-dns retrying), keep the default — it's the buffer that lets a reboot pass silently. If you're tempted to override, ask: "would this log line appear during a 5-min planned reboot?" If yes, default. If it only appears when something is *actually* broken, `threshold = 0`.

**`forDuration` — transient bursts that self-heal (the persistence dimension):**

`threshold` filters by **volume in a window**; `forDuration` filters by **duration**. They are orthogonal knobs and the difference matters when a service emits a *short burst* of matching lines that exceeds `threshold` but then recovers on its own.

Added 2026-06-06 (default `forDuration = "0s"` — page on the first positive eval, i.e. unchanged for every existing pattern). The motivating case: Jellystat logged exactly 3 `Connection terminated due to connection timeout` lines in a ~10s span as its DB pool briefly stalled, then recovered. With the default `threshold = 2` that's `3 > 2` → instant page, even though nothing was actually broken 20 seconds later.

Raising `threshold` is the wrong tool here — a fast enough burst still clears any volume bar, and you can't pick a count that separates "3 lines in 10s, self-healed" from "3 lines in 5m, dying" because they have the same count. The distinguishing signal is **how long the condition persists**:

- A one-off burst keeps the `count_over_time` value elevated for ~`window` (the burst sits in the trailing window) then decays to 0. So the alert condition is true for at most ~`window`.
- A genuinely broken service keeps erroring every few seconds, so the condition stays true indefinitely.

Set `forDuration` **safely above `window`** and the burst can never satisfy the pending period, while the sustained failure sails past it. The rule group evaluates every 1m, so `forDuration = "10m"` means "true for 10 consecutive evals." Example — Jellystat: `window = 5m` (default), `forDuration = "10m"`. A burst holds the condition true for ~5m then drops (never reaches 10m → no page); a dead `jellystat-db` keeps erroring and pages ~10m after onset.

| Pattern shape | `forDuration` | Why |
|---|---|---|
| Terminal / single-shot (`panic`, `FATAL`, backup give-up, migration failed) | `"0s"` (default) | Must page on first occurrence; pairs with `threshold = 0`. |
| Sustained-failure with a brief self-healing failure mode (DB pool blips, connection-pool exhaustion that retries clear) | `> window` (e.g. `"10m"` for a 5m window) | Suppresses the self-healing burst; still pages a real sustained outage, just later. |

**Tradeoff:** a real outage pages `forDuration` later (~10m vs ~1m). Only acceptable for **warning/degraded** patterns where a few minutes' latency is fine. Never put a long `forDuration` on a `critical` user-visible-breakage pattern. And don't reach for it when `threshold` already does the job — `forDuration` is specifically for "burst exceeds threshold but self-heals," not for general noise reduction.

**Severity tiering:**

| Severity | When to use | Bridge priority |
|---|---|---|
| `critical` | Service is unusable; user-visible feature broken (uploads, login, search). | Gotify 8 (high) |
| `warning` | Degraded — some users affected, retries may recover, partial functionality. | Gotify 5 |
| `info` | Worth knowing about but no action expected. | Gotify 5 (rare; usually means the pattern shouldn't be an alert) |

**Pattern hygiene:**

- Use `(?i)` for case-insensitive only when needed; not all services log lowercase consistently.
- Avoid backreferences and lookarounds — Loki's regex engine is `re2`, no support.
- Test the pattern in Grafana Explore before committing: `{host="<host>", unit="<unit>"} |~ "<pattern>"` should return real failures over the last 30 days. If it returns zero, the pattern is wrong (no test data) or the failure class never happens (great, but verify).
- For Postgres-backed services, include `PostgresError|permission denied for table` to catch the #250 class globally.
- For Node/Express services, `UnhandledPromiseRejection|Cannot set headers after they are sent` are common but noisy — only include if they fire on real failures in your audit window.

**Investigation flow when a pattern fires:**

1. Read the Gotify push — claude has already classified the failure class.
2. Open Grafana Explore with the LogQL from the alert annotation (already pre-filled in the description).
3. Look at the matching lines + surrounding minutes for context (stack traces, preceding errors).
4. Cross-check related units (e.g. if `immich-server` fires, check `immich-machine-learning` and `container@immich-db.service`).

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

**Layout is scope (#234, 2026-06-08).** A secret under `secrets/hosts/<host>/` is encrypted to *that host's* key only (plus the universal editor + break-glass keys) — it does not decrypt fleet-wide. Put a service's secret under its host's directory unless it is genuinely consumed on multiple hosts, in which case add an explicit multi-host rule in `secrets/.sops.yaml`. The recipient scoping is enforced by `sopsRecipientScopeCheck` in `flake.nix`, with a fail-closed `.*` fallback (editor + break-glass only) so a new, unscoped secret deploys to no host until given a rule. Full recipient model + recovery: [`docs/wiki/infrastructure/sops-break-glass-recovery.md`](infrastructure/sops-break-glass-recovery.md).

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
  # REQUIRED: runtime hardening baseline (see below).
  extraOptions = config.homelab.podman.hardenOptions ++ [ /* --user / --cap-add / --device */ ];
};
```

### Container runtime hardening (REQUIRED on every OCI container)

We never pin images — `:latest` + auto-pull stays on fleet-wide by explicit
policy (issue #232 TIER-4 is **WONTFIX**; do not propose a `:latest`/`:master`
CI gate or digest pinning, see `.claude/memory/feedback-no-image-pinning.md`).
The compensating control for a compromised auto-pulled image is to shrink its
runtime authority. So **every** `virtualisation.oci-containers.containers.<name>`
must prepend `config.homelab.podman.hardenOptions` to its `extraOptions`:

```nix
extraOptions = config.homelab.podman.hardenOptions ++ [ ... ];
```

`hardenOptions` is `["--security-opt=no-new-privileges" "--cap-drop=all"]`
(readOnly — a module can't weaken it; exceptions are **additive** via cap-add).
Then `--cap-add` back only the minimal set the container actually needs:

| Container shape | cap-add needed |
|---|---|
| Plain app run as `--user=<uid>:<gid>` on an unprivileged port (Node/Go/etc.) | *none* — `hardenOptions` alone |
| Static exporter / single binary as root, unprivileged port | *none* |
| s6 / LSIO / jlesage init that starts root, chowns state, drops to PUID/PGID | `CHOWN SETUID SETGID DAC_OVERRIDE FOWNER KILL` |
| Binds a privileged (<1024) port | add `NET_BIND_SERVICE` |
| GPU transcode | add `--device=/dev/dri/renderD128:...` (a device map, **not** a cap) |

Notes:
- cap-drop=all does **not** affect `--device` GPU access (device perms/cgroup, not a capability) nor reading bind-mounts as the runtime UID.
- If an s6-style container fails to start after hardening, check its logs — some s6-overlay versions also want `SETPCAP` to drop the bounding set. Add it explicitly, don't widen back to default caps.
- Exception of record: `hermes` (its own locked VM) is deliberately left at podman defaults until its tool requirements are mapped — see the header in `modules/nixos/services/hermes-agent.nix`. Any new container has no such excuse.

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
- **OCI container without `config.homelab.podman.hardenOptions`** in its
  `extraOptions`. Default podman caps (CHOWN, SETUID, DAC_OVERRIDE, NET_RAW, …)
  are a fat runtime for a compromised image. Every container must start from
  `hardenOptions` (cap-drop=all + no-new-privileges) and cap-add back only what
  it needs. See "Container runtime hardening" above.
- **`pull = "newer"` on `:latest`/`:master` tags is FINE and intended** — by
  explicit policy we keep auto-pull on for everything and do **not** pin images
  (issue #232 TIER-4 is WONTFIX; see
  `.claude/memory/feedback-no-image-pinning.md`). The supply-chain mitigation is
  *runtime hardening* (`hardenOptions`, above), **not** pinning. Do not add a
  `:latest`/`:master` CI gate or digest pin.
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

> **Policy:** we do **not** pin container image tags — `:latest` + auto-pull is
> on fleet-wide and that is a hard line (issue #232 TIER-4 = WONTFIX; see
> `.claude/memory/feedback-no-image-pinning.md`). The trade is accepted
> knowingly; the mitigation is runtime hardening (`hardenOptions`), not pinning.
> The items below are therefore about *containing* an untrusted image, not
> freezing it.

- **Personal Dockerhub repos** (`docker.io/<personal-handle>/...`) — single
  author, no signing. We run them anyway (auto-pull stays on), so the runtime
  hardening baseline matters most here: cap-drop=all, non-root `--user` where
  possible, narrow bind mounts. If a project is unmaintained *and* its behaviour
  is simple, prefer vendoring into `pkgs.dockerTools` (reproducible, no external
  pull) — that is the only acceptable "freeze," and it's about build provenance,
  not tag pinning.
- **Tracking upstream `master` of a `flake = false` input that builds an
  image we run** (`musicbrainz-docker` learned this on 2026-05-10 when the
  PG16→PG18 bump broke our cluster — #228, #229). This is a *flake input*, not a
  container tag — those we do review on bump, because a broken build wedges the
  whole host. Distinct from the no-pinning policy for pulled images.

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
  human-named NFS directory, expose a space-free runtime path via the per-
  unit `BindPaths=` sandbox pattern below — symlinks were the prior workaround
  but the 2026-05-20 paperless incident showed they fail silently when
  `ReadWritePaths=` is involved.

### Sandbox patterns — `ReadWritePaths` vs `BindPaths`

systemd's two ways to make a path writable in an otherwise-`ProtectSystem=strict`
unit have very different failure semantics, which matters for paths backed by
NFS or accessed through symlinks. From systemd.exec(5):

- **`ReadWritePaths=` / `ReadOnlyPaths=` / `InaccessiblePaths=` silently skip
  missing sources.** "If the path itself or any of its parents do not exist
  on the host, the corresponding mount will be skipped." Convenient for
  defining protections that should work across hosts. Dangerous when the
  source is on NFS or behind a symlink whose target lives on NFS — a
  concurrent mount manipulation (switch-to-configuration touching mount
  units, NFS automount idle, watchdog probe) can race the unit's namespace
  setup and the rw bind is silently not created. First write fails with
  `EROFS` minutes or hours later, with no log line tying the failure to
  the setup race.
- **`BindPaths=src:dst` / `BindReadOnlyPaths=src:dst` are fail-loud.**
  Missing or unbindable source → `status=226/NAMESPACE` and a
  `Failed to set up mount namespacing: <path>: <reason>` entry in
  journald. The unit refuses to start until the source is bindable.

**Rule.** For service-critical mount-ins on NFS-backed paths, use `BindPaths=`,
not `ReadWritePaths=`. Always pair with a `Failed at step NAMESPACE`
`errorPatterns` entry so a real bind failure pages.

### Narrowing `/mnt` visibility — `TemporaryFileSystem=/mnt`

`ProtectSystem=strict` + `PrivateMounts=yes` do **not** narrow which `/mnt/*`
paths a unit can see. They privatise the namespace and bind `/usr` / `/boot`
/ `/etc` ro, but every host mount under `/mnt` is inherited as-is. On doc2
that means a default-hardened service can read all of `/mnt/data`,
`/mnt/appdata`, `/mnt/mum`, `/mnt/mirrors`, `/mnt/virtio` even when its
legitimate scope is two NFS subdirs.

For services where the visible-mount blast radius matters (anything stateful
that touches NFS, or anything with credentials that could pivot to other
services' on-disk state), wrap the unit's `/mnt` in a fresh tmpfs and bind
back only what's needed:

```nix
serviceConfig = {
  TemporaryFileSystem = "/mnt";
  BindPaths = [
    "${realMediaDir}:${mediaDir}"   # space-bearing src → space-free dst
    "${realScansDir}:${consumeDir}"
    "${cfg.dataDir}"                # src==dst when no rename needed
  ];
};
```

`TemporaryFileSystem=` only affects the unit's own namespace, never the host.
Combined with `BindPaths=` this gives both least-privilege scope **and**
fail-loud failure if a bind source goes away.

Spaces in `BindPaths=` sources: escape as `\ ` (backslash-space) in the unit
value. In Nix, the indented-string form `''/path/with\ space''` writes the
right bytes directly. `\x20` does **not** work — the BindPaths parser takes
it literally.

#### Default for new doc2 services (#257)

As of the #257 audit, **`TemporaryFileSystem=/mnt` is the default for every new
doc2 service**, not an opt-in. doc2 has six-plus NFS/virtiofs exports under
`/mnt`; the default-hardened (or unhardened) unit sees all of them. Pick the
right shape:

- **No `/mnt` state at all** (HTTP-only helpers, services whose state is in a
  DB container or `/var/lib`): `serviceConfig.TemporaryFileSystem = "/mnt";`
  with **no** `BindPaths`. Blank tmpfs, nothing bound back. `TemporaryFileSystem`
  forces a private mount namespace on its own, so this works even when upstream
  leaves `PrivateMounts=no`.
- **Needs one or more `/mnt/*` subdirs**: add `BindPaths = [ ... ]` for exactly
  those (src==dst when no rename needed; `src:dst` to rename a space-bearing
  source to a space-free mountpoint).

Two rules that bit us during the audit:

1. **Order the unit after its bind sources.** `BindPaths` is fail-loud, so if a
   virtiofs/NFS source isn't mounted yet at unit start the unit dies with
   `226/NAMESPACE` during early boot. Add
   `unitConfig.RequiresMountsFor = [ <each bound /mnt path> ];` — it resolves to
   the backing `*.mount` unit and both orders-after and pulls-in. (Old
   `ReadWritePaths=` hid this by silently skipping the unmounted source; the
   fail-loud bind exposes it.)
2. **errorPattern policy.** Add a `Failed at step NAMESPACE` `errorPatterns`
   entry **only when the unit binds a real `/mnt/*` source** that can disappear
   (NFS stale, dataset unmounted). A blank-`/mnt`-no-bind unit has nothing to
   fail on — a tmpfs-only namespace effectively never fails to set up — so skip
   the pattern there and rely on the HTTP/Kuma monitor (note this in a comment).
   For units that already have an errorPattern for their main service, append
   `|Failed at step NAMESPACE` to the existing alternation rather than adding a
   second entry.

See `docs/wiki/infrastructure/systemd-sandbox-mnt.md` for the failure-mode
narrative this rule grew out of and the per-service audit findings, and
`modules/nixos/services/paperless.nix` for the canonical implementation
(`forgejo.nix` for the two-bind / NFS-dump variant).

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
- [ ] OCI containers prepend `config.homelab.podman.hardenOptions` to
      `extraOptions` and `--cap-add` back only the minimal set (see Container
      runtime hardening). Do NOT pin image tags — auto-pull stays on (policy)
- [ ] App listens on `127.0.0.1`, exposed via `homelab.localProxy.hosts`
- [ ] `homelab.localProxy.hosts` entry for DNS/SSL/nginx
- [ ] If MOVING a `localProxy` service between hosts: deploy the destination
      (new) host first, then the source — and both in one maintenance window.
      Never commit the same FQDN on two hosts (see "Moving a `localProxy`
      service between hosts" above and `services/local-proxy-dns-sync.md`)
- [ ] `homelab.monitoring.monitors` entry for health checking
- [ ] Stateful services: `homelab.monitoring.deepProbes` entry with
      service-specific probe script under `modules/nixos/services/probes/`,
      OR an explicit comment justifying why a shallow HTTP check is
      sufficient (high bar — see Deep probes section above)
- [ ] `homelab.monitoring.errorPatterns` entries for the service's
      real failure log fingerprints, OR an explicit
      `errorPatterns = []` with a comment justifying (services where
      every failure surfaces as HTTP 5xx — bar is high; see
      Per-service errorPatterns section)
- [ ] `homelab.nfsWatchdog` if service depends on NFS paths
- [ ] Secrets via `sops.secrets` + `config.homelab.secrets.sopsFile`
- [ ] No hardcoded LAN IPs in module code or runtime config (see DNS-First Networking above)
- [ ] No hardcoded passwords in `environment` attrsets — use `environmentFiles`
- [ ] Any `fileSystems` entry whose source lives on a network filesystem
      carries `_netdev` (and ideally `nofail`); see Mount ordering anti-pattern
- [ ] No `fileSystems` mountpoint contains literal spaces; use space-free
      service-facing paths via `TemporaryFileSystem=/mnt`+`BindPaths=`
      instead (see Sandbox patterns section)
- [ ] **doc2 services: `TemporaryFileSystem=/mnt` on every unit** (default, not
      opt-in — see "Default for new doc2 services"). Blank tmpfs + `BindPaths=`
      for exactly the `/mnt/*` paths the unit needs (often none)
- [ ] Every bound `/mnt/*` source has a matching
      `unitConfig.RequiresMountsFor` entry so the fail-loud bind can't race the
      mount at boot
- [ ] For NFS-backed writable paths: use `BindPaths=` not `ReadWritePaths=`
      (fail-loud vs silent-skip), and add `Failed at step NAMESPACE` to the
      `errorPatterns` of any unit that binds a real `/mnt/*` source (skip it for
      blank-`/mnt`-no-bind units — nothing to fail on)
- [ ] Service enabled in appropriate host config
- [ ] `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` succeeds
