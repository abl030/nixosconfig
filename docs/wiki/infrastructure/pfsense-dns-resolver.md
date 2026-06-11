# pfSense as the fleet DNS resolver

**Date researched:** 2026-05-23
**Status:** Tuned (2026-05-23). Was chronically saturated under stock defaults.
**Related incident:** [dns-saturation-incident-2026-05-22](dns-saturation-incident-2026-05-22.md).
**Backup architecture:** [pfsense-backup](pfsense-backup.md) (ZFS-pull-to-prom + dual-Kopia off-site).

## Role

pfSense (`192.168.1.1` on LAN, `100.123.61.111` on Tailscale — **same physical box, two interfaces**) is the **single recursive DNS resolver for the entire fleet**. It runs on **bare metal** — a dedicated small appliance, not a VM on `prom`. No ZFS, no PBS, no vzdump available; backup options are pfSense-native (config.xml + ACB). Every NixOS host's `tailscaled` runs as the local stub resolver and forwards upstream queries to pfSense. pfSense's unbound then forwards out to Cloudflare DoT (`1.1.1.2:853`, `1.0.0.2:853`).

If pfSense's unbound stops answering, **the whole fleet loses non-MagicDNS resolution within seconds** — including build sandboxes, package fetches, and any service that hits public hostnames.

## Management plane: LAN-only (2026-06-07)

pfSense's admin surfaces are reachable **only from the LAN** (`192.168.1.0/24`) — not over Tailscale, the IoT/Docker VLANs, or WAN. Tightened on 2026-06-07 as part of the least-privilege work in [#239](https://github.com/abl030/nixosconfig/issues/239): pfSense is a non-NixOS member of the open tailnet mesh with no container-hardening fallback, so locking its admin plane is the compensating control.

- **Web GUI (`:443`) and SSH (`:22`):** floating `quick` block rules (IDs 39–46, direction=any) drop traffic to "This Firewall" on those ports arriving on the Tailscale, Docker-VLAN (OPT3), IoT-VLAN (OPT4), and WAN interfaces. The LAN anti-lockout rule is untouched, so admin from `192.168.1.0/24` is preserved.
- **DNS (`:53`) is deliberately exempt.** The whole fleet forwards DNS to pfSense over *both* the LAN and the Tailscale interface (see "Role" above — tailscaled holds persistent TCP/53 to `100.123.61.111`). The block rules are scoped to the admin ports only. A blanket "block tailnet → This Firewall" would take DNS down fleet-wide — **never** add a to-firewall block on the Tailscale interface without carving out `:53`.

Verify from a fleet host with both paths: GUI/SSH on `192.168.1.1` succeed, the same ports on `100.123.61.111` time out, and `dig @100.123.61.111 <name>` still resolves. Rules live on the appliance only (not in this repo); roll back by deleting the floating block rules in the GUI. Never flush states.

## Non-obvious facts that have bitten us

1. **`100.123.61.111` and `192.168.1.1` are the same box.** Tailscale interface and LAN interface of pfSense. Logs that mention both addresses are not describing two failures — they're describing one resolver being asked twice via two paths.
2. **`tailscaled` uses TCP/53 for forwarded queries in our environment.** Each NixOS host holds ~4 persistent ESTABLISHED TCP connections to pfSense's :53 at idle (sample on any fleet host: `sudo ss -tnp '( dport = :53 )'` — process is `tailscaled-wra…`). Public Tailscale docs and [tailscale#11632](https://github.com/tailscale/tailscale/issues/11632) suggest UDP-only forwarding; empirically wrong for our config. ~10 hosts × ~4 connections = ~40 persistent TCP slots needed.
3. **ntopng runs on pfSense itself, not on doc2.** doc2 only runs the Go `ntopng-exporter` (HTTP scraper, no DNS). All ntopng `--dns-mode` settings are pfSense-side.
4. **The wiki note in `modules/nixos/services/loki.nix:427-429` is load-bearing**: `service ntopng onestart` silently starts ntopng without SSL. Always restart via `/usr/local/etc/rc.d/ntopng.sh restart` so the ntopng-exporter on doc2 can still reach the HTTPS endpoint.
5. **pfSense filter logs ship to Loki; unbound and system logs do not.** Investigating unbound issues requires the pfsense subagent or direct SSH — `loki` will not show you what unbound is doing. See [lgtm-stack](../services/lgtm-stack.md) for current shipping config.

## Tunables we set (2026-05-23)

These are the deviations from stock pfSense 2.8.x defaults. All are runtime-applicable; no reboot needed (unbound restart picks up the unbound side).

### System → Advanced → System Tunables

| Tunable | Value | Stock | Why |
|---|---|---|---|
| `kern.ipc.soacceptqueue` | `4096` | `128` | FreeBSD default capped unbound's TCP/53 listen queue at an effective ceiling of 193 (kernel uses `× 1.5`). Saturated 15–20 times/day under fleet baseline. |
| `kern.ipc.maxsockbuf` | `16777216` | `2097152` | Required so unbound can request larger SO_RCVBUF/SO_SNDBUF on TCP/53. Without it, raising `incoming-num-tcp` doesn't help. |

### DNS Resolver → General Settings → Custom Options

```
server:
    incoming-num-tcp: 100
    outgoing-num-tcp: 100
    serve-expired-client-timeout: 1800
```

- `incoming-num-tcp` and `outgoing-num-tcp` are **per thread**. Stock default `10` × 4 threads = 40 slots, exactly equal to the persistent tailscaled load — no headroom. `100` gives 10× margin.
- `outgoing-num-tcp` matters as much as incoming because we forward to Cloudflare over DoT: every upstream query is TCP/TLS.
- `serve-expired-client-timeout: 1800` (milliseconds — yes, ms not s) puts unbound in RFC 8767 mode. Without it, `serve-expired: yes` returns stale answers immediately *and* fires a synchronous upstream refresh, piling TCP/TLS connections onto an already-stressed pool. With it, unbound waits ~1.8s for a fresh answer first.

## Restart commands

- **unbound:** `pfSsh.php playback svc restart unbound` (or `kill -HUP $(cat /var/run/unbound.pid)` if playback is slow).
- **ntopng:** `/usr/local/etc/rc.d/ntopng.sh restart` — **never** `service ntopng restart` or `service ntopng onestart` (silently starts without SSL).

## Loki queries (pfSense logs now ship as of 2026-05-23)

pfSense's syslog forwards to doc2 Loki on UDP/1514. Useful labels: `host="pfsense"`, `app=<program>`. Currently observed `app` values: `unbound`, `kea2unbound`, `filterlog`, `filterdns`, `nginx`, `kea-dhcp4`, `kernel`, `php-fpm`, `php-cgi`, `php`, `syslogd`, `check_reload_status`, `dhclient`.

```logql
# Unbound operational events (errors, restarts, module load/exit)
{host="pfsense", app="unbound"}

# pfBlockerNG DNSBL block events — they come through unbound's syslog channel
# with [pfBlockerNG] prefix, NOT under app="pfBlockerNG"
{host="pfsense", app="unbound"} |~ "\\[pfBlockerNG\\]"

# Listen-queue overflow detection (canary for the saturation problem this wiki documents)
{host="pfsense", app="kernel"} |~ "sonewconn|Listen queue overflow"

# Kea/unbound lease sync events (causes brief unbound reloads — see kea2unbound footgun)
{host="pfsense", app="kea2unbound"}
```

At unbound `verbosity: 1` (the only verbosity worth running in production), unbound is silent during normal operation — non-zero output means an actual event worth looking at.

## Investigative commands

```sh
# Is unbound healthy / restart-looping?
ps auxw | grep -i unbound
sockstat -4 -l | grep ':53 '

# Recent TCP/53 listen-queue overflows
grep 'Listen queue overflow' /var/log/system.log | tail -20
# "193 already in queue" = stock somaxconn=128 (× 1.5)
# "6144 already in queue" = tuned soacceptqueue=4096 (× 1.5)

# Live unbound config — picked up after restart
unbound-control get_option incoming-num-tcp
unbound-control get_option outgoing-num-tcp
unbound-control get_option serve-expired-client-timeout

# Who's actually using TCP/53?
sockstat -4 | grep ':53'
```

From a fleet host (to see what tailscaled is doing):

```sh
sudo ss -tnp '( dport = :53 )'
# Process should be tailscaled-wra<...>
```

## Known footguns

### kea2unbound reload-per-lease

`kea2unbound` reloads unbound on every Kea DHCP lease state change (lease grant, expiry, release). Each reload briefly pauses TCP/53 accept. Short-lived clients (phones roaming, IoT devices like `yoto-mini`) cause noticeable mini-blips. **Workaround:** static-map noisy clients. **Known bugs:** [Redmine #15651](https://redmine.pfsense.org/issues/15651), [Redmine #15663](https://redmine.pfsense.org/issues/15663).

### pfBlockerNG DNSBL mode

The **`dnsbl_python`** mode (Python module intercepts queries in-process) is the correct one. Avoid the older "Unbound mode" (DNSBL feed updates → unbound restart storm → zombie unbound). Check via:

```sh
grep dnsbl /var/unbound/unbound.conf | head
# "module-config: \"python validator iterator\"" → correct
```

### pfBlockerNG IP feeds can false-positive CDN anycast IPs

Distinct from DNSBL (domains): pfBlockerNG's **IP** reputation feeds (e.g.
Project Honeypot `HoneyPot_*`) populate `pfB_*` pf deny tables. They periodically
flag individual IPs inside shared CDN anycast ranges (Fastly/Cloudflare/Akamai),
which silently breaks legit destinations sharing that IP. On 2026-06-07 this
blocked **cache.nixos.org** (`151.101.0.0/16`, Fastly) fleet-wide and was
misdiagnosed as an ISP fault for hours. Full RCA + the diagnostic lesson
("test reachability from pfSense itself to tell our-end from the ISP") and the
suppression-list how-to:
[pfblockerng-fastly-block-incident-2026-06-07](pfblockerng-fastly-block-incident-2026-06-07.md).

```sh
# Is an IP in a deny table, and which feed put it there?
pfctl -t pfB_PRI4_v4 -T test <ip>
grep -rl <ip> /var/db/pfblockerng/deny/
# Fix: suppress the owning CIDR/ASN (config.xml installedpackages/pfblockerngipsettings,
# base64) + Force Reload. Never flush states.
```

### ntopng's `--dns-mode=1` PTR firehose

Initiates reverse-DNS lookups on every IP it observes. On a busy LAN, this generates a sustained stream of loopback PTR queries that saturate unbound's TCP slots during bursts. **Current setting: `--dns-mode=2`** (passive decode only, no initiated lookups). Stored in `config.xml` under `<installedpackages><ntopng><dns_mode>` and generated into `/usr/local/etc/ntopng.conf`. Modes:

| Mode | Behaviour |
|---|---|
| 0 | No PTR resolution |
| 1 | Resolve every numeric IP (firehose — avoid) |
| 2 | Decode PTRs that flow through naturally, never initiate (**our setting**) |
| 3 | Local-only PTR (LAN IPs) |

### ntopng table caps (memory diet, 2026-06-11)

The FW4C has only **4 GB RAM + 1 GB swap**, and swap had been pegged at 100 %
since at least 2026-05-23 (start of Loki ingestion), with unbound OOM-killed
near-daily — see
[alloy-loki-wildcard-dns-incident-2026-06-10](alloy-loki-wildcard-dns-incident-2026-06-10.md)
for the fleet-visible fallout. The two userspace hogs: unbound at ~950 MB RES
(~850 MB of that is the pfBlockerNG python DNSBL holding **4.6 M domains**
in-process — kept by choice) and ntopng at ~680 MB and growing (6 interfaces,
default 131072-entry host/flow tables each).

Fix applied 2026-06-11: per-interface table caps via the ntopng package's
`custom_config` field (`config.xml` →
`installedpackages/ntopng/config/0/custom_config`, base64). It is appended to
the generated `/usr/local/etc/ntopng.conf` and **survives GUI saves and
package upgrades** (handled in `/usr/local/pkg/ntopng.inc`):

```
--max-num-hosts=16384
--max-num-flows=32768
```

Result: ntopng RES ~680 MB → ~300 MB at restart, swap 100 % → 72 %.
If RES creeps back over ~400 MB, tighten the flow cap. Restart **only** via
`/usr/local/etc/rc.d/ntopng.sh restart` (see the restart gotcha above).
Do not grow swap instead — it's ZFS-on-root on the appliance SSD; sustained
thrash is a disk-wear problem, not a fix.

### serve-expired's two modes

`serve-expired: yes` alone is a footgun (stale-immediately + sync refresh = upstream pile-up). Pair it with `serve-expired-client-timeout: <ms>` for RFC 8767 behaviour. Unbound docs: [serve-stale](https://unbound.docs.nlnetlabs.nl/en/latest/topics/core/serve-stale.html).

### Memory leak in pfBlockerNG Python module

Long-running unbound RSS grows past ~800 MB on pfBlockerNG 3.2.x. Restarting unbound clears it. Tracked in [Redmine #11316](https://redmine.pfsense.org/issues/11316), partially fixed in later 3.2.x releases. **Upgrade pfBlockerNG via GUI** (System → Package Manager → Installed Packages) — not via the package API, which can skip the post-install DNSBL rebuild hook.

## Editing unbound config via API: cache-coherence gotcha

The pfSense REST API endpoint `pfsense_update_services_dns_resolver_settings` (and the equivalent GUI save path) **serialises its in-memory cached view back to config.xml** when called. If you `sed`-edit `<unbound>` fields directly and then call the API for an unrelated change, your sed edits get silently overwritten with whatever the API had cached.

Safe pattern when editing `<unbound>` fields outside the API:

1. Read current state (`grep` config.xml).
2. Edit via `sed` (or write the API call).
3. Force a fresh re-parse: PHP `parse_config(true)` — bypasses cache.
4. Regenerate `unbound.conf` via `services_unbound_configure()` (or equivalent).
5. Restart unbound.
6. Verify by `grep` of the actual `unbound.conf`, not config.xml.

Symptom of the bug: your sed value is in config.xml briefly, then mysteriously reverts. Fix: re-apply the sed edits *after* any API calls have settled, then force `parse_config(true)` before regenerating.

## Backup and rollback

`/cf/conf/config.xml` is the live config. Take a timestamped copy before changes:

```sh
cp /cf/conf/config.xml /tmp/config-backup-$(date +%Y%m%d%H%M%S).xml
```

Restore by copying back and triggering a config reload (or rebooting). Package binaries are NOT rolled back by config restore — for package issues, reinstall via the GUI.

## DoH/DoT bypass blocking (forced DNS) — automated 2026-06-05

To keep untrusted clients on pfSense's resolver (above) we block known **DoH** (443) and **DoT** (853) endpoints for three source populations: the `DHCP_Dynamic` range (`.100–.254`), the LG TV (`192.168.1.42`), and the `IOT_of_Death` interface. DoT is blocked broadly (`any → any:853`); DoH is blocked against a list of resolver IPs.

**The old way (retired):** a hand-curated `host`-type firewall alias `DoH_Providers` (~250 entries, pasted from the [Hagezi DoH list](https://github.com/hagezi/dns-blocklists) — no provenance was recorded in config; the giveaway was Hagezi's own NS hostnames in the entries). Two problems: (1) it rotted — public DoH endpoints get decommissioned, leaving dead NXDOMAIN entries; (2) **`filterdns` re-resolves every hostname in every `host`-type alias every ~5 min**, so each dead entry logged `failed to resolve host … will retry later again` forever, flooding `{host="pfsense", app="filterdns"}` in Loki.

**The new way:** a pfBlockerNG IPv4 feed `pfB_DoH_v4` (a `urltable` alias) sourced from [`dibdot/DoH-IP-blocklists`](https://github.com/dibdot/DoH-IP-blocklists) `doh-ipv4.txt`, action **Alias Native** (maintains the alias only, no auto-rules), riding the existing pfBlockerNG update cron. ~1664 IPs, auto-refreshed. The three block rules (LAN DHCP_Dynamic, LG TV, IOT) point their destination at `pfB_DoH_v4`. Because it's an IP `urltable`, **`filterdns` never touches it** — retiring `DoH_Providers` killed the resolution flood entirely as a side effect, not just the four dead entries.

**Lesson:** for blocklists of *named* endpoints that change over time, use a maintained IP feed via pfBlockerNG (`urltable`), never a hand-curated `host` alias — the latter rots AND filterdns floods the log re-resolving it. The DoT side (`any:853`) needs no list and is unaffected.

Also fixed in the same pass: the LG TV's DoH (rule 27) and DoT (rule 28) rules hardcoded `192.168.1.36`, but the TV had moved to `.42` (`.36` is doc2-vpn). Both rules now target `.42`, confirmed against the `lgwebostv` DHCP static mapping. Hardcoded device IPs in rules are a standing footgun — prefer a static-mapping-backed alias if this recurs.

## When to revisit

- If listen-queue overflows reappear in `system.log` despite the tunes: check unbound RSS (leak), check pfBlockerNG mode, check if a new noisy DHCP client is causing kea2unbound churn.
- If the fleet grows past ~25 NixOS hosts, the per-thread `incoming-num-tcp: 100` may need another bump (~200) given each host's persistent ~4-connection footprint.
- Tailscale ≥ a future major version may change tailscaled's DNS-forwarding behaviour back to UDP-first — sample TCP/53 socket counts and adjust if so.
