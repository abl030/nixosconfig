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

pfSense's `syslog.remoteserver` field does not resolve hostnames — it's an IP+port string only. Short names and FQDNs both fail silently. We use `192.168.1.35:1514` literally. Documented workaround + toggle-off-on dance in `stacks/loki/README.md`.

### Tempo is still empty

No apps in our fleet push OTEL traces. See `docs/observability-plan.md` for the investigation — current answer is that most homelab apps only expose Prometheus metrics. Tempo infrastructure + OTLP receivers are ready for when something lands.

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

## When to revisit

- When someone wires an OTEL-native app → Tempo receivers come alive. Add source restriction for 4317/4318.
- When we migrate the firewall to nftables → collapse `extraCommands` back into `extraInputRules`.
- When we move LGTM to yet another host → follow the migration runbook (scrub old localProxy cache; deploy new; deploy old; update `docker/unraid-alloy/config.alloy` if FQDN default isn't used; re-point pfSense IP).
- When grafana DB accumulates real secrets → rotate `GRAFANA_SECRET_KEY` in `secrets/loki.env` (seeded to grafana's historical upstream default `SW2YcwTIb9zpOOhoPsMm` so an old compose-era grafana.db can decrypt if ever migrated).

## Related

- `modules/nixos/services/loki-server.nix` — server config
- `modules/nixos/services/loki.nix` — alloy shipper + syslog receiver (`homelab.loki`)
- `stacks/loki/README.md` — pfSense syslog config details + label reference
- `docs/observability-plan.md` — OTEL/Prometheus roadmap
- `docker/unraid-alloy/` — tower's alloy shipper
