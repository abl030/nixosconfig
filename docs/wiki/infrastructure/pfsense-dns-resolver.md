# pfSense as the fleet DNS resolver

**Date researched:** 2026-05-23
**Status:** Tuned (2026-05-23). Was chronically saturated under stock defaults.
**Related incident:** [dns-saturation-incident-2026-05-22](dns-saturation-incident-2026-05-22.md).

## Role

pfSense (`192.168.1.1` on LAN, `100.123.61.111` on Tailscale — **same physical box, two interfaces**) is the **single recursive DNS resolver for the entire fleet**. Every NixOS host's `tailscaled` runs as the local stub resolver and forwards upstream queries to pfSense. pfSense's unbound then forwards out to Cloudflare DoT (`1.1.1.2:853`, `1.0.0.2:853`).

If pfSense's unbound stops answering, **the whole fleet loses non-MagicDNS resolution within seconds** — including build sandboxes, package fetches, and any service that hits public hostnames.

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

### ntopng's `--dns-mode=1` PTR firehose

Initiates reverse-DNS lookups on every IP it observes. On a busy LAN, this generates a sustained stream of loopback PTR queries that saturate unbound's TCP slots during bursts. **Current setting: `--dns-mode=2`** (passive decode only, no initiated lookups). Stored in `config.xml` under `<installedpackages><ntopng><dns_mode>` and generated into `/usr/local/etc/ntopng.conf`. Modes:

| Mode | Behaviour |
|---|---|
| 0 | No PTR resolution |
| 1 | Resolve every numeric IP (firehose — avoid) |
| 2 | Decode PTRs that flow through naturally, never initiate (**our setting**) |
| 3 | Local-only PTR (LAN IPs) |

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

## When to revisit

- If listen-queue overflows reappear in `system.log` despite the tunes: check unbound RSS (leak), check pfBlockerNG mode, check if a new noisy DHCP client is causing kea2unbound churn.
- If the fleet grows past ~25 NixOS hosts, the per-thread `incoming-num-tcp: 100` may need another bump (~200) given each host's persistent ~4-connection footprint.
- Tailscale ≥ a future major version may change tailscaled's DNS-forwarding behaviour back to UDP-first — sample TCP/53 socket counts and adjust if so.
