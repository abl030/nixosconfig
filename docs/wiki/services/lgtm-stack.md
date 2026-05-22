# LGTM observability stack

**Last updated:** 2026-04-15
**Status:** working
**Owner:** `modules/nixos/services/loki-server.nix` (server) + `modules/nixos/services/loki.nix` (alloy shipper on every NixOS host)
**Issue:** [#208](https://github.com/abl030/nixosconfig/issues/208)

## Where it lives

- **Host:** doc2 (VM on prom)
- **Data:** `/mnt/virtio/loki/{grafana,loki,tempo,mimir}` — virtiofs, disposable VM
- **FQDNs:** `https://logs.ablz.au` (grafana), `https://loki.ablz.au`, `https://tempo.ablz.au`, `https://mimir.ablz.au`

Cloudflare A records are owned by `homelab.localProxy` on whichever host declares `homelab.services.loki.enable = true`. Moving the server → deploy the new host, scrub old host's `/var/lib/homelab/dns/records.json` first (see "localProxy cache footgun" below), deploy old host.

Previously ran on igpu as a rootless podman compose stack. Migrated April 2026 because igpu should only host iGPU-dependent services (jellyfin, plex, tdarr transcoding).

## Architecture

All four services via upstream nixpkgs modules (`services.{grafana,loki,tempo,mimir}`). One wrapper module at `modules/nixos/services/loki-server.nix` providing `homelab.services.loki.{enable,dataDir,*Port,retentionHours}`.

```
                                      ┌──────────────┐
  fleet alloy ───HTTPS──────────────▶ │   nginx      │ ──▶ 127.0.0.1:3100 loki
  tower alloy ───HTTPS──────────────▶ │  (ACME, 443) │ ──▶ 127.0.0.1:3200 tempo
                                      │              │ ──▶ 127.0.0.1:9009 mimir
                                      │              │ ──▶ 127.0.0.1:3030 grafana
                                      └──────────────┘
  pfSense ──UDP 1514 (source-restricted)──▶ alloy syslog receiver on doc2
                                              └──▶ 127.0.0.1:3100 loki
```

HTTP endpoints are never open to the LAN — nginx terminates HTTPS on 443 and proxies to localhost. OTLP receivers (4317/4318) stay open for future trace emitters (no current sources).

## Non-obvious things we learned

### dskit gRPC ring self-discovery (critical)

`grafana-loki`, `mimir`, and `tempo` all use `dskit` for their internal rings. dskit advertises **the resolved host IP** (not `grpc_listen_address`) as its ring endpoint, then dials that IP to reach its own replicas. Binding `grpc_listen_address = "127.0.0.1"` on a multi-service host will pass module eval, bind the port on loopback… then break at runtime with `connection refused` on `<lan-ip>:<grpc-port>` because the advertised endpoint isn't reachable.

**Fix in this module:** bind all three to `grpc_listen_address = "0.0.0.0"` and just don't open the gRPC ports on the firewall. Pin each service to a distinct gRPC port (tempo 9095, loki 9096, mimir 9097) — default 9095 collides.

### Grafana port collision

Grafana defaults to port 3000. `mealie`'s gotenberg sidecar on doc2 also binds `127.0.0.1:3000` (for PDF rendering). Grafana silently failed to start until moved to 3030. If we migrate grafana to a different host one day, 3000 might be free again — the option default stays 3030 to keep doc2 working.

### Static users for tempo/mimir on virtiofs

Upstream `services.tempo` and `services.mimir` default to `DynamicUser = true`, which assigns a random UID per activation. Virtiofs on doc2 persists file ownership across VM rebuilds — so a DynamicUser-owned state dir is unreadable after the next rebuild. Module overrides to static `tempo:tempo` / `mimir:mimir` users with `WorkingDirectory` pinned to `/mnt/virtio/loki/<name>`.

Grafana and Loki already use static users upstream, so they don't need the override.

### Firewall backend: iptables, not nftables

Our NixOS hosts still use the iptables firewall backend (no `networking.nftables.enable = true`). `networking.firewall.extraInputRules` is silently ignored on iptables — first tightening attempt used that syntax and pfSense syslog stopped reaching the receiver because the unconditional port-open went away but the source-restricted nftables rule wasn't active.

**Fix:** use `networking.firewall.extraCommands` with iptables syntax (`iptables -I nixos-fw 1 -p udp --dport 1514 -s 192.168.1.1 -j nixos-fw-accept`). If we flip to nftables later, extraInputRules can return alongside.

### localProxy cache footgun (migration-time only)

`homelab.localProxy` keeps `/var/lib/homelab/dns/records.json` per host. It tracks Cloudflare record IDs it has PUT for each FQDN. During a migration:

1. New host (doc2) runs its sync → for `loki.ablz.au`, queries Cloudflare, finds igpu's existing record ID, PUTs an update with the new IP. doc2's cache and igpu's cache **both now reference the same record ID**.
2. Old host (igpu) redeploys with the FQDN dropped from its `localProxy.hosts` → cleanup loop sees `loki.ablz.au` in its cache but not in desired_hosts → **DELETEs the shared record ID** → DNS vanishes.

**Fix during migration:** scrub old host's cache before redeploying it.
```
ssh <old-host> 'sudo rm /var/lib/homelab/dns/records.json'
```
Next sync rebuilds the cache from the host's desired_hosts only. Nothing to clean up, nothing to wipe.

### pfSense syslog target is an IP, not a DNS name

pfSense's `syslog.remoteserver` field does not resolve hostnames — it's an IP+port string only. Short names and FQDNs both fail silently. We use `192.168.1.35:1514` literally.

### Tempo is still empty

No apps in our fleet push OTEL traces. Most homelab apps only expose Prometheus metrics. Tempo infrastructure + OTLP receivers are ready for when something lands.

## pfSense Prometheus exporter

**Added:** 2026-04-16 (Phase 4 of #208)

OCI container `ghcr.io/pfrest/pfsense_exporter` on doc2, configured via `homelab.loki.pfsenseExporter.enable = true`. Polls pfSense's REST API package for metrics and exposes them on `:9945/metrics`.

**Metrics coverage:** CPU, memory, disk, swap, mbuf, interface bytes/packets/errors, firewall state count, gateway latency + loss + status (WAN_DHCP, AirVPN, AirVPN_SG), CARP status, service health, temperature.

**Architecture:** multi-target exporter pattern — alloy scrapes `localhost:9945/metrics?target=192.168.1.1` (the `targetParam` option in `extraScrapeTargets` emits `__param_target` in alloy HCL). Config.yml generated at runtime from sops (`secrets/pfsense-mcp.env` — reuses the existing pfSense REST API key).

**pfSense host IP exception:** `192.168.1.1` is hardcoded as the default because pfSense IS the gateway — no localProxy-managed FQDN exists. Documented exception to the DNS-first rule. The option is configurable if the IP ever changes.

**Prerequisites on pfSense:** the `pfSense-pkg-RESTAPI` package must be installed. It's removed on every pfSense major upgrade and must be reinstalled manually.

**Thermal metrics:** `pfsense_system_temperature_celsius` requires the `coretemp` FreeBSD kernel module on pfSense. Enabled via `System > Advanced > Miscellaneous > Thermal Sensors = Intel Core`, or `kldload coretemp` + `/boot/loader.conf.local` entry for persistence. Without it, the metric emits 0.

## ntopng per-client traffic exporter

**Added:** 2026-04-16

For the per-host / per-flow visibility that the REST-API exporter can't give. Module: `homelab.loki.ntopngExporter.enable = true` on the host running loki-server.

- **On pfSense:** `ntopng` + `redis` packages installed. Bound to LAN interface only on `:3000` (HTTPS, reusing the pfSense webgui cert). DNS resolve mode = 1 ("resolve all numeric IPs"). 6 interfaces monitored: `igc0` (WAN), `igc1` (LAN), `igc1.10` (Docker VLAN), `igc1.100` (IoT VLAN), `tun_wg0` (AirVPN SG), `tun_wg2` (AirVPN NZ). `localSubnets` scoped to `192.168.1.0/24 + 192.168.11.0/24 + 192.168.101.0/24 + 224.0.0.0/4` to cap series cardinality.
- **On doc2:** OCI container `aauren/ntopng-exporter:latest` polls ntopng's REST API every 60s and exposes `:9946/metrics`. Config YAML generated at runtime from sops env (`secrets/hosts/doc2/ntopng.env` — `NTOPNG_USER` + `NTOPNG_PASSWORD`). Self-signed TLS accepted (`allowUnsafeTLS = true`) since connection stays on LAN.
- **Metrics shape:** `ntopng_host_bytes_{sent,rcvd}{ip, mac, ifname, name, vlan}` — per-client, per-interface bandwidth. Plus `ntopng_interface_*` for pure interface totals, `ntopng_host_total_{client,server}_flows`, DNS query counts, alert counts.
- **Cardinality:** ~100 clients × 6 interfaces × ~10 metrics ≈ 6k active series. `localSubnetsOnly` keeps internet destinations out of the series space.

**Upstream does NOT publish to grafana.com.** Canonical dashboard lives in the exporter repo at `resources/grafana-dashboard.json` — tracked as flake input `ntopng-exporter-src` so nightly flake update picks up upstream revisions.

### ntopng has two rc scripts on pfSense — only one starts HTTPS

Bitten by this during the 2026-04-17 incident (below). pfSense's ntopng package installs **two** rc scripts side by side:

| Script | What it runs | SSL? |
|---|---|---|
| `/usr/local/etc/rc.d/ntopng` | Bare FreeBSD rc, hardcoded `command_args` with NO conf file | **No** — HTTP-only on :3000 |
| `/usr/local/etc/rc.d/ntopng.sh` | pfSense-package generated wrapper: `/usr/local/bin/ntopng /usr/local/etc/ntopng.conf` | **Yes** — `ntopng.conf` contains `--https-port=192.168.1.1:3000` |

`service ntopng onestart` (the obvious "just restart it" incantation) invokes the **bare script**, so it brings ntopng up without SSL. The ntopng-exporter on doc2 is configured for `https://192.168.1.1:3000` — so when HTTPS silently disappears, the exporter's TLS handshake gets 5 bytes of garbage from the HTTP server, interprets it as a failed scrape, and returns empty for every interface. The exporter's `/metrics` shrinks to just Go runtime stats (48 samples) and every panel goes "No Data" without an obvious error.

**Correct manual restart:** `/usr/local/etc/rc.d/ntopng.sh restart` (stop + start, HTTPS preserved).

**Never use:** `service ntopng onestart` or `service ntopng start`.

### Service Watchdog needs ntopng registered in `installedpackages/service[]`

pfSense's `pfSense-pkg-Service_Watchdog` monitors services via `is_service_running()` (which works fine for anything with a process), but when it tries to restart a failed service it calls `service_control_start("<name>", ...)`. That function's `default:` branch ends up in `start_service()` in `service-utils.inc`, which searches `installedpackages/service[]` in `config.xml` for an rcfile entry — if the service isn't there, it silently no-ops.

**ntopng is not registered by its package in that array.** So a Watchdog-only setup (monitor enabled, no registration) will **detect** a down ntopng and log "Restarting ntopng", but nothing actually restarts.

**Fix:** inject an `installedpackages/service` entry pointing at `ntopng.sh` (not the bare `ntopng` rc — see section above):

```xml
<service>
  <name>ntopng</name>
  <rcfile>ntopng.sh</rcfile>
  <executable>ntopng</executable>
  <description>ntopng Network Monitoring (HTTPS)</description>
</service>
```

`rcfile = ntopng.sh` is the load-bearing field — `start_service()` constructs `/usr/local/etc/rc.d/ntopng.sh start` from it. `executable = ntopng` is only used as a `killall` fallback by `stop_service()`. Entries in this array do NOT cause pfSense to auto-start the service on boot; it's purely a lookup table for `start_service()`/`stop_service()` calls.

**Validate** the whole chain works:

```sh
# On pfSense:
pkill -9 ntopng        # simulate crash
php /usr/local/pkg/servicewatchdog_cron.php   # run the watchdog check synchronously
pgrep ntopng           # should return a PID within a few seconds
curl -skI https://192.168.1.1:3000/   # should return 302 with self-signed cert
```

The watchdog cron runs every minute on its own; `php ...servicewatchdog_cron.php` just forces an immediate run for testing.

### 2026-04-17 incident summary

- **09:23:49 AWST** — ntopng segfaulted on pfSense (`pid N (ntopng), exited on signal 11 — no core dump — bad address`). Single journal line, no follow-up.
- Dashboard silently went flat from ~09:30 onwards. No alert fired because the exporter target stayed `up=1` (the sidecar was still serving `/metrics`, just with no ntopng data left to scrape).
- **~13:00** — user noticed during Grafana work.
- pfsense subagent did `service ntopng onestart` → ntopng was up but on HTTP-only (see above) → exporter still returned empty.
- Traced via `curl -skI http://192.168.1.1:3000/` returning 302 while HTTPS failed TLS handshake → discovered the two-rc-script split.
- Restarted via `ntopng.sh restart`, HTTPS back, exporter recovered within one 60s scrape cycle.
- Then discovered the Watchdog registration gotcha while verifying auto-restart worked. Registered ntopng in `installedpackages/service[]`; verified a `pkill -9` → 3-second restart cycle.

**Root cause of the original segfault is unknown** — pfSense's ntopng 6.2.250909 is out-of-tree from upstream ntopng and occasional crashes under sustained load are a known class of issue. No core dump (FreeBSD default — `kern.coredump=1` + a `coredumpdir` would help if it recurs). We decided coredump capture isn't worth the state-dir footprint unless it crashes again. Watchdog + the registration fix above is the safety net.

**Detection gap that let this go unnoticed for 4h:** `up{job="ntopng"}` stays 1 when only ntopng (not the exporter) dies. A better alert would fire on `absent_over_time(ntopng_interface_num_devices[10m])` or on the drop in `scrape_samples_scraped{job="ntopng"}`. Not yet implemented — TODO when another dashboard gap appears and this becomes a pattern.

### Custom dashboard: "ntopng — Client Traffic"

**Added:** 2026-04-17. Lives at `dashboards/ntopng-client-traffic.json` — our own, not a flake input.

**Why it exists:** the vendored `aauren/ntopng-exporter` dashboard is noisy and confusing for the thing we actually want: "how much is flowing over WAN + each VPN tunnel, and which LAN client is responsible." The vendored one repeats stat panels per interface (including empty VPN ones), collapses into row-repeats that silently fail to render when template vars resolve weird, and doesn't flag VPN-routed clients. This custom one is narrower:

1. Three stat panels — WAN / AirVPN NZ / AirVPN SG current bps.
2. A single timeseries with those three interfaces overlaid.
3. A LAN top-talkers **table** with a "Route" column showing VPN or Direct per host.
4. A top-10 LAN timeseries underneath for historical context.

**Key design note — why "VPN" is inferred from LAN-side policy-routing, not observed on the tunnel:** ntopng can't see individual LAN clients on `tun_wg*` interfaces. From ntopng's point of view, the only host on a WireGuard tunnel is the tunnel endpoint itself (or multicast leaking onto it). LAN clients get NAT'd into the tunnel before ntopng's observation point on the VPN side. So the only way to answer "which LAN clients are using the VPN" is to consult pfSense's policy-routing config and check LAN-side bytes for those IPs.

### VPN-routed IP sync contract

`homelab.loki.ntopngExporter.vpnClientIPs` in `modules/nixos/services/loki.nix` is a mirror of pfSense's `MV_VPN_IPS` alias. It's plumbed into the custom dashboard at Nix build time via a regex substitution (Nix `builtins.replaceStrings` — not sed, because sed eats the backslashes we need for JSON-escaped dots in a PromQL regex).

The contract:

- **Source of truth is pfSense** (operational state — rules fire from the alias).
- **Nix mirror is doc2** (`hosts/doc2/configuration.nix`).
- **Propagation requires a rebuild** of doc2. The regex is baked into the dashboard at build time, so a drift between the two silently mis-tags hosts without raising an error.

When modifying MV_VPN_IPS via the pfsense subagent:
1. Subagent updates the pfSense alias.
2. Subagent updates `vpnClientIPs` in `hosts/doc2/configuration.nix` to match.
3. Subagent reminds the user to rebuild doc2.
4. Subagent audits both sides agree after the change.

This is codified in `.claude/agents/pfsense.md` front-matter under "Cross-repo sync contract: MV_VPN_IPS ↔ Nix" — future pfsense sessions enforce it automatically.

### Fleet dashboard audit — 2026-04-17

During the ntopng incident investigation we swept every provisioned dashboard for silent failures. Summary — 8 dashboards, fleet is healthy:

| Dashboard | Health | Notes |
|---|---|---|
| pfSense Firewall / Gateways / Interfaces / Services / System / Traffic | OK | All panels rendering, all template variables populate |
| ntopng-exporter | **Fixed** | See incident summary above |
| Node Exporter Full | **Partial (UX trap)** | Defaults to `nodename=Tower` (Unraid). Unraid's node_exporter doesn't emit `node_pressure_*`, `node_filesystem_*` for `/`, or swap, so Pressure / Root FS / SWAP panels show N/A. Not a pipeline failure — the metrics genuinely don't exist on that host. |

**Node Exporter Full `nodename=Tower` default** is the only outstanding item. Fixing it cleanly would mean patching the vendored JSON at build time in `loki-server.nix` (same pattern as the ntopng `${PROM}` + `irate` rewrites). The simplest sed replacement is to change the variable's `current.value` and `current.text` from `"Tower"` to `"doc2"` (or any host with full Linux metrics). Not urgent — users can pick a proper host from the dropdown — but worth doing next time we touch that module.

## Declarative Grafana dashboards

**Pattern** (see `loki-server.nix` — `dashboardsDir` runCommand): flake inputs hold git-tracked dashboard JSON, a `pkgs.runCommand` stages them into a single directory, Grafana's `provision.dashboards.settings.providers` points at that path with `disableDeletion = false` so removed files actually disappear on next deploy.

**Current flake inputs used**:
- `grafana-dashboards-rfmoz` — "Node Exporter Full" (grafana.com/1860)
- `pfsense-exporter-src` — 7 pfSense dashboards (CARP filtered out in runCommand)
- `ntopng-exporter-src` — per-client traffic dashboard

**Gotchas — any community dashboard may need build-time patching:**

1. **`${PROM}` input placeholders.** Dashboards designed for Grafana's interactive import flow embed `uid: "${PROM}"` references that only get resolved when the user picks a datasource during import. File-provisioned dashboards skip that prompt — `${PROM}` stays literal, every panel shows "no data". Fix: sed-replace `${PROM}` with our pinned datasource UID at build time. See ntopng dashboard handling.
2. **Hardcoded datasource name "Prometheus".** Community dashboards commonly save their datasource variable's `current.value` as the string `"Prometheus"`. Panels then reference `uid: "$datasource"`, which expands to that string — so the datasource UID MUST equal `"Prometheus"` or panels fail silently. We pin `uid = "Prometheus"` on our mimir-backed prom datasource. Note: `deleteDatasources` in nixpkgs grafana provisioning is NOT idempotent — using it to rename the old "Mimir" entry will error on subsequent deploys once the target is gone.
3. **`irate([1m])` on 60s scrape.** Dashboards often assume a 15s scrape cadence and use short rate windows. At our 60s cadence, `irate(...[1m])` typically has only 1 sample in-window → NaN → "no data". Fix: build-time sed replacement of `irate(...[1m])` with `rate(...[5m])`, OR set `jsonData.timeInterval = "60s"` on the datasource so `$__rate_interval` resolves to `4 × scrape = 240s` (covers dashboards that use the macro but not those with hardcoded `[1m]`).

## DNS-first rule

**Rule:** all observability shipping URLs use Cloudflare FQDNs, never hardcoded LAN IPs.

Why: we verified from doc1, tower, and other hosts that `<service>.ablz.au` resolves everywhere via public DNS, while `<host>` short names only work where Tailscale MagicDNS is present and `<host>.ablz.au` isn't a standard pattern (and can pick up stale records — `doc2.ablz.au` currently points at 192.168.1.6, a ghost host).

The only exception is pfSense syslog, forced to raw IP by pfSense itself (see above).

## Alerting → Gotify

**Added:** 2026-04-16 (issue [#201](https://github.com/abl030/nixosconfig/issues/201))
**Module:** `modules/nixos/services/alerting.nix` (`homelab.services.alerting`)

We use **Grafana's built-in alerting** (not standalone Alertmanager) and route notifications to **Gotify via a webhook contact point**. No Alertmanager is deployed — Grafana already has a full alerting engine, and adding another layer would only buy us features we don't use yet.

### Why a webhook works directly with Gotify (no bridge)

Gotify's `POST /message?token=X` endpoint accepts JSON bodies and picks up the top-level `title` and `message` fields, ignoring everything else in the payload. Grafana's default webhook payload happens to put both fields at the top level alongside its alertmanager-style metadata — so Gotify silently extracts the two it cares about and discards the rest. No body-template override, no translation bridge.

Verified by sending a synthetic Grafana-shape payload to the contact-point URL on 2026-04-16 — Gotify created message id 2571 (appid 7) and delivered the push.

### How the token stays out of the Nix store

The contact-point URL needs `?token=<secret>`. Grafana's `services.grafana.provision.alerting.contactPoints.settings` (Nix-native) would serialise that into the store. To avoid leaking:

1. We declare `contactPoints.path = "/var/lib/grafana-alerting/contactPoints.yaml"` (a runtime-mutable path, not a store path).
2. A oneshot prestart unit (`grafana-alerting-prestart.service`) materialises that file before grafana starts: reads the sops-decrypted token from `/run/secrets/gotify-alerting/token`, sed-substitutes a `__GOTIFY_TOKEN__` placeholder in a store-side template, writes the result.
3. `requiredBy = ["grafana.service"]` + `before = ["grafana.service"]` makes grafana wait on prestart and fail-stop if it errors.
4. `restartTriggers` on `grafana.service` keyed off the prestart unit's derivation hash means URL/token-extraction changes propagate via `nixos-rebuild switch` (otherwise grafana would keep its in-memory contact points until manually restarted).

Same pattern as `pfsense-exporter` in `loki.nix` — both bind a runtime-rendered config to an upstream service's startup.

### sops-nix dotenv gotcha (already cost an hour once)

`sops.secrets.X = { format = "dotenv"; key = "GOTIFY_TOKEN"; ... }` does **NOT** extract the bare value — the materialised file content is the literal `KEY=VALUE` line. Verified on doc2: `/run/secrets/gotify/token` is 29 bytes containing `GOTIFY_TOKEN=AJ.SqA-aYIJDnFU\n`. The `gotify-ping.sh` script handles both formats defensively, and the alerting prestart strips `${raw#GOTIFY_TOKEN=}` for the same reason.

Don't try to use `$__file{/run/secrets/gotify/token}` directly in a Grafana webhook URL — it would inject the `GOTIFY_TOKEN=` prefix into the URL and break the request.

### The reboot alert (the canonical first rule)

`homelab-reboot-prom`: fires when `time() - node_boot_time_seconds{instance="prom"} < 600`. One notification per reboot, auto-resolves after 10 minutes. The DAG is `query → reduce → threshold` — Grafana 10+ requires this explicit shape (no PromQL `ALERT` short form). `for: 0s` because reboot detection is binary; `noDataState/execErrState: OK` so a Mimir blip doesn't fire spurious alerts.

The motivating incident: prom hard-crashed at 02:17 AWST on 2026-02-22, went unnoticed until morning because igpu (which then hosted Loki) was also down. With LGTM now on doc2 and this alert rule, a future reboot pages immediately.

To add more reboot alerts, append instance labels to `homelab.services.alerting.rebootAlert.instances` — one alert rule per instance, no duplication needed.

### Token reuse vs split

Currently reuses `secrets/gotify.env` (`GOTIFY_TOKEN`) — same Gotify "application" stream as agent pings. If the noise mix becomes a problem, create a separate Gotify app, store its token in `secrets/gotify-alerting.env`, and point `homelab.services.alerting.gotifyTokenSopsFile` at it.

### alert-bridge — claude-summarised Gotify pushes (added 2026-05-20)

Grafana and Kuma both have verbose default webhook payloads (30+ lines per alert: LogQL, DAG metadata, raw monitor body); reading them on a phone at speed is painful. `modules/nixos/services/alert-bridge.nix` runs a small Python HTTP listener on `127.0.0.1:9876` between BOTH systems and Gotify. When `homelab.services.alertBridge.enable = true`:

- `alerting.nix` automatically swaps Grafana's webhook URL from the direct-Gotify form to the bridge URL.
- `monitoring_sync.nix` declaratively provisions a Kuma webhook notification (`alert-bridge`, isDefault=true) pointing at the bridge (#256).

**Per-alert flow.** The bridge detects payload shape on each POST:

**Grafana shape** (`alerts: [...]` at top level):
1. For each `status=firing` alert, read `labels.loki_lines` and run that raw stream-selector against Loki to fetch up to 10 matching lines (10m window). `labels.loki_query` is the aggregated form used for the alert *condition* and returns scalar counts — don't use it for context.
2. Compose `## Alert metadata` + `## Matching log lines` block, pipe to `claude -p --model opus --allowedTools ""`.
3. Push summary to Gotify with severity-aware priority (critical → 8, others → 5). Resolved alerts skipped.

**Kuma shape** (`heartbeat` + `monitor` at top level — added 2026-05-20, #256):
1. Skip recovery (UP) events. Only DOWN (`heartbeat.status = 0`) fires the bridge.
2. For push-type monitors, infer the corresponding systemd unit via the `probeSlug` convention (`Kopia mum freshness` → `deep-probe-kopia-mum-freshness.service`) and `journalctl --since=20min -n 40` to fetch the probe's stdout/stderr — this is the actual diagnostic context.
3. For HTTP-type monitors, the journal fetch is skipped (no per-monitor unit to read); the bridge passes the URL, status code, ping ms, and Kuma's `msg` field to claude as the only context.
4. Compose `## Kuma monitor DOWN` block + optional `## Recent journal for <unit>`, pipe to the same claude system prompt (which knows both formats), and push.

The system prompt knows about both shapes and produces the same 2-3 line output format either way, so the phone push looks consistent.

**Why opus, not haiku:** the DDL classification needs reasoning over actual log lines (operator session vs drift), not pattern-match. Audit alerts are rare so cost isn't a concern. `homelab.services.alertBridge.model` overrides per-host.

**Why `labels.loki_lines` matters:** the alert *condition* needs the aggregation (`sum(count_over_time(...))`) to produce a numeric series to threshold on. But running that same query for context returns the count, not the text. Two label slots split the concern. `mkLokiAlert`'s `lokiLines` argument is optional — Prometheus rules can skip it and the bridge falls through to metadata-only context.

**Auth gotcha:** the bridge runs as `abl030` because `claude-code` auth lives in `~/.claude` after the one-time interactive `sudo -u abl030 --login claude` setup. Same constraint as `nixos-upgrade-diagnose` in `modules/nixos/autoupdate/update.nix`. The bridge service has its own sops decryption of the Gotify token (`alert-bridge/gotify-token`) with `owner=abl030` so the systemd service can read it.

**Group gotcha:** systemd service `Group=` needs a real group; `abl030` user has primary group `users` (not a group named `abl030`). Use `Group = "users"` in the service config.

**Journal access for Kuma push enrichment.** The bridge service has `SupplementaryGroups = ["systemd-journal"]` so `journalctl -u deep-probe-<slug>.service` works without sudo. Plus `PATH=${pkgs.systemd}/bin` since journalctl isn't in the default `writeShellApplication` runtime PATH. Without these, push-monitor enrichment silently degrades — the alert still fires but claude sees only Kuma metadata, no journal context.

**Re-alert cadence:** the bridge itself doesn't dedupe — that's Grafana's notification policy (`repeat_interval = "24h"`) and Kuma's per-monitor `resendInterval`. Effective re-page cadence is documented in the next subsection.

**probeSlug must stay in sync** between `monitoring_sync.nix` (Nix-side, used to build push monitor names) and `alert-bridge.nix` (Python-side, used to reverse-map names to systemd units). If you change one, change both. The exact replacements: `/` → `-`, `space` → `-`, `(` → ``, `)` → ``, `—` → `-`, `[` → ``, `]` → ``, then lowercase.

### DB DDL audit rules (added 2026-05-20 via #251)

Two Loki-backed alert rules in the `db-audit` group:

- `homelab-pg-superuser-ddl` — fires on any PG superuser DDL in a `container@*-db.service` journal that isn't tagged `application_name=mk-pg-container-startup`. Catches both legitimate operator shell sessions (machinectl shell → psql) and silent drift like the `asset_edit_audit` incident (#250).
- `homelab-mariadb-audit-ddl` — fires on any MariaDB `server_audit` `QUERY_DDL` event from a user not in `server_audit_excl_users` (local socket root/mysql are excluded as ops backdoor).

Both depend on inner-container postgres/mariadb logs reaching Loki, which only works because `mk-pg-container.nix` routes through syslog rather than the inner journal — see [`docs/wiki/infrastructure/nspawn-journal-shipping.md`](../infrastructure/nspawn-journal-shipping.md) for the why.

### Loki datasource UID auto-generation gotcha

The Loki datasource in `loki-server.nix` has no explicit `uid:` — Grafana auto-generates one at first startup (currently `P8E80F9AEF21F6940` on doc2). Pinning the UID at provisioning time *after* the datasource already exists breaks Grafana with `Datasource provisioning error: data source not found` because the upsert path can't change UIDs in-place, and the `deleteDatasources` workaround would risk breaking dashboards that reference Loki by UID.

For declarative alert rules that need to reference Loki, expose the UID as a module option and document the lookup command:

```sh
PASS=$(sudo grep ^GRAFANA_ADMIN_PASSWORD= /run/secrets/loki/grafana.env | cut -d= -f2-)
curl -sG -u "abl030:$PASS" http://127.0.0.1:3030/api/datasources \
  | jq -r '.[] | select(.name=="Loki").uid'
```

If we ever nuke `/var/lib/grafana` (or migrate hosts), update the default in `homelab.services.alerting.dbAuditAlert.lokiDatasourceUid` to the new auto-UID. Same Prometheus pinning rationale applies but Prometheus *was* pinned cleanly from day 1; Loki was created without a UID before we needed declarative alerting against it.

### Maintenance windows

Not implemented. The motivating use case is "alert me when prom reboots, full stop" — the user usually knows when they're about to reboot prom and can ignore the page. If we end up with regular planned-reboot windows, add a Grafana mute timing via `services.grafana.provision.alerting.muteTimings.settings` and reference it from the policy.

## Shipper resilience — alloy WAL + retry budget

**Researched:** 2026-05-22. **Status:** deployed (NixOS module + ansible template + unraid compose), live on prom.

### What broke

2026-05-21 ~20:18-20:30 UTC, doc2 ran its nightly `nixos-upgrade` and rebooted. Loki/Mimir were unreachable for ~12 minutes. Alloy on `prom` exhausted its retry budget at minute 7 and emitted `final error sending batch, no retries left, dropping data` — one Loki batch lost. Other fleet hosts' batches happened to retry past the gap and recovered. No Mimir data was lost (prometheus.remote_write has a built-in on-disk WAL).

### Why it could happen at all

The default `loki.write` block in alloy uses **`max_backoff_period = 5m, max_retries = 10`** and has **WAL disabled**. Exponential backoff (500ms × 2^n) caps at the 5m ceiling and gives up ≈9 min after the first failure. Anything longer than that drops batches.

This is asymmetric with `prometheus.remote_write`, which keeps an on-disk WAL by default — that's why Loki has historically been the only side to drop on doc2 reboots.

### The fix

Two changes on every alloy instance:

```hcl
loki.write "loki" {
  endpoint {
    url = "..."
    max_backoff_period = "10m"   # was 5m
  }
  wal {
    enabled         = true        # was off
    max_segment_age = "2h"
  }
}
```

- `max_backoff_period = 10m` keeps the in-memory queue alive through the normal ~15-min maintenance reboot window.
- `wal { enabled = true }` persists queued batches to `/var/lib/alloy/data/loki.write.<name>/` so they survive even longer outages AND alloy restarts. `max_segment_age = 2h` caps how stale a replayed segment can be — past that we accept the loss rather than ship hours-old logs.

### Four places to keep in sync

Every alloy instance in the fleet must carry these settings. Today:

| Host(s) | Config source | Notes |
|---|---|---|
| All NixOS hosts (`homelab.loki = true`) | `modules/nixos/services/loki.nix` (`alloyConfig` heredoc) | Canonical. Rolls via `rolling-flake-update.service` overnight. |
| `prom`, `pbs-tower`, `pve-epi` (Proxmox/Debian) | `ansible/common/templates/alloy-config.alloy.j2` | Deployed via `ansible/common/monitoring.yml`. Inventories: `prom_prox/`, `epi_prox/`, `pbs_tower/`. |
| `tower` (Unraid) | `docker/unraid-alloy/config.alloy` + `docker-compose.yml` | Compose command must include `--storage.path=/var/lib/alloy/data` so WAL lands in the `alloy-data` named volume, not the container's writeable layer. |

If you change one, change all four. Drift here means silent log loss the next time doc2 reboots.

## Per-service errorPattern alerts — startup-noise trap

**Researched:** 2026-05-22.

Loki errorPattern alerts ([`homelab.monitoring.errorPatterns`](../../../modules/nixos/services/monitoring_sync.nix)) compile to `sum(count_over_time({...} |~ "<pattern>" [<window>]))` with `for: 0s` and a 10-minute Grafana frame. Two consequences worth knowing:

1. **A single matched log line keeps the alert firing for `window + 10m`**, then resolves. With the default `window = "5m"`, that's the **exactly 15-minute** "fire → resolve" cycle seen on flap alerts. This is by design, but means a startup transient that matches once still pages for 15 min.

2. **Tailscale daemons print "You are logged out … fetch control key: … context canceled" during normal boot**, before the first successful key fetch. This matches a naive `(?i)logged out\.` pattern. Every podman auto-update of a `ts-*` sidecar therefore looked like a real auth loss until 2026-05-22.

**General rule for errorPattern regexes on container/service logs:** distinguish *startup race* signatures from *operational failure* signatures. For tailscale specifically:

- ❌ `logged out\.` — matches startup health-check line on every restart.
- ❌ `fetch control key.*context canceled` — matches container shutdown race.
- ✅ `control:.*(401|unauthorized)` — coordinator actively rejected.
- ✅ `key (expired|rejected|invalid)` — auth key dead.
- ✅ `control: logout` — explicit logout.

For belt-and-suspenders on any pattern that *might* match transient startup chatter, set `threshold = 1, window = "10m"` — requires 2+ matches in 10 min, so a single boot-time emission cannot page. Real failures repeat on every coordinator poll.

See `modules/nixos/services/tailscale-share.nix:260-280` for the canonical example.

## Kuma push-monitor boundary race — why `maxretries = 2` lied

**Researched:** 2026-05-22. **Status:** fixed (default bumped to `10` in `modules/nixos/services/monitoring_sync.nix` deepProbe schema).

### What broke

`Immich sync write-path` push monitor went DOWN at **11:09:50 AWST** and paged via the bridge. Heartbeat history showed it had received a perfectly clean UP at **11:07:50**, only 2 minutes before the DOWN. Next push at **11:12:50** resolved it. Total false-alert window: ~3 min. The probe systemd unit was running every 5 min on schedule, exit 0, with normal IP traffic — no probe-side issue.

### Why

Kuma's push monitor scheduler runs an internal tick that, when the time since the last received heartbeat exceeds `interval`, inserts a synthetic "No heartbeat in the time window" entry and counts a retry. After `maxretries` retries, the monitor flips DOWN.

The race today on monitor 59 (Immich sync, `interval=300, maxretries=2, retryInterval=60`):

| Local time | Event |
|---|---|
| 11:02:49 | probe push received → UP |
| 11:07:49 | Kuma tick: `now - last_hb = 300s`, deadline hit → synthetic PENDING |
| 11:07:50 | probe push arrives **1s late** — Kuma records the UP, but the PENDING entry from 1s earlier is already in the table and the retry counter is armed |
| 11:08:50 | Kuma tick: still counting → PENDING (retry 1) |
| 11:09:50 | Kuma tick: counting → DOWN (retry 2 = maxretries) → **bridge fires** |
| 11:12:50 | probe push received → UP → resolves |

The probe didn't fail. The probe wasn't late by any meaningful measure. The probe drifted 1s past Kuma's deadline because of normal systemd `AccuracySec=10s` jitter plus ~20ms curl round-trip latency. With `maxretries = 2`, Kuma's DOWN tick wins the race against the next regularly-scheduled push.

### What the docstring claimed vs reality

The `deepProbes.maxretries` option docstring used to say:

> Default 2 with intervalSecs=300 = ~15 min of continuous failure before alerting.

That arithmetic was wrong. The formula is `intervalSecs + maxretries * retryInterval`, so with the old defaults it was `300 + 2*60 = 420 s = 7 min` — and in practice, the boundary race makes effective tolerance closer to zero whenever push timing drifts by ≥1 s past `interval`.

### The fix

Default bumped to `maxretries = 10`. Time-to-DOWN now `300 + 10*60 = 900 s = 15 min`, which matches what the docstring originally claimed AND survives the 1-s boundary race comfortably. Existing deepProbes (Immich sync, Kopia mum freshness, Kopia photos freshness) inherit the new default — none had an explicit override.

### General lesson

Push-monitor `maxretries` is **not** "tolerance for repeated probe failures" the way active-monitor `maxretries` is. It's "how many `retryInterval` cycles past the original `interval` deadline you'll tolerate before pulling the alarm." If your probe runs on a timer that aligns within tens of seconds of the Kuma interval (any systemd timer does, by default), you must budget for boundary jitter — `maxretries = 2` will flap.

## When to revisit

- When someone wires an OTEL-native app → Tempo receivers come alive. Add source restriction for 4317/4318.
- When we migrate the firewall to nftables → collapse `extraCommands` back into `extraInputRules`.
- When we move LGTM to yet another host → follow the migration runbook (scrub old localProxy cache; deploy new; deploy old; update `docker/unraid-alloy/config.alloy` if FQDN default isn't used; re-point pfSense IP).
- When grafana DB accumulates real secrets → rotate `GRAFANA_SECRET_KEY` in `secrets/loki.env` (seeded to grafana's historical upstream default `SW2YcwTIb9zpOOhoPsMm` so an old compose-era grafana.db can decrypt if ever migrated).

## Related

- `modules/nixos/services/loki-server.nix` — server config
- `modules/nixos/services/loki.nix` — alloy shipper + syslog receiver (`homelab.loki`)
- `modules/nixos/services/alerting.nix` — Grafana alerting → Gotify (`homelab.services.alerting`, #201)
- `modules/nixos/services/monitoring_sync.nix` — `errorPatterns` option schema (`window`, `threshold`)
- `ansible/common/templates/alloy-config.alloy.j2` + `ansible/common/monitoring.yml` — alloy on Proxmox/Debian hosts (prom, pve-epi, pbs-tower)
- `docker/unraid-alloy/` — tower's alloy shipper
