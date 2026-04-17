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

### Maintenance windows

Not implemented. The motivating use case is "alert me when prom reboots, full stop" — the user usually knows when they're about to reboot prom and can ignore the page. If we end up with regular planned-reboot windows, add a Grafana mute timing via `services.grafana.provision.alerting.muteTimings.settings` and reference it from the policy.

## When to revisit

- When someone wires an OTEL-native app → Tempo receivers come alive. Add source restriction for 4317/4318.
- When we migrate the firewall to nftables → collapse `extraCommands` back into `extraInputRules`.
- When we move LGTM to yet another host → follow the migration runbook (scrub old localProxy cache; deploy new; deploy old; update `docker/unraid-alloy/config.alloy` if FQDN default isn't used; re-point pfSense IP).
- When grafana DB accumulates real secrets → rotate `GRAFANA_SECRET_KEY` in `secrets/loki.env` (seeded to grafana's historical upstream default `SW2YcwTIb9zpOOhoPsMm` so an old compose-era grafana.db can decrypt if ever migrated).

## Related

- `modules/nixos/services/loki-server.nix` — server config
- `modules/nixos/services/loki.nix` — alloy shipper + syslog receiver (`homelab.loki`)
- `modules/nixos/services/alerting.nix` — Grafana alerting → Gotify (`homelab.services.alerting`, #201)
- `docker/unraid-alloy/` — tower's alloy shipper
