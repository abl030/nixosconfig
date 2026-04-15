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
