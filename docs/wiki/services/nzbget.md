# NZBGet

**Last updated:** 2026-06-18
**Status:** active on **tower** (Unraid) — NZBGet 26.1
**Owner:** NOT in this repo. Runs as a Docker container on the Unraid host
(`tower`, 192.168.1.2). Has its own LAN IP **192.168.1.17** via an ipvlan on
`br0`. Public URL `https://nzbget.ablz.au` (Caddy → the container).
**Config file:** `/config/nzbget.conf` inside the container.

NZBGet is the Usenet downloader. It is **not** managed by this NixOS repo — the
only repo reference is doc2's egress allowlist (`hosts/doc2/configuration.nix`,
`192.168.1.17 # tower nzbget`). Manage it through its web UI or the JSON-RPC API.

## Controlling it via the JSON-RPC API

NZBGet exposes a full JSON-RPC API that covers **settings**, not just queue
control. Reach it directly on the LAN (fastest, no Cloudflare round-trip):

```
http://192.168.1.17:6789/jsonrpc/<method>
```

Auth is HTTP Basic. There are three credential tiers in `nzbget.conf`; only the
**Control** tier (`ControlUsername` / `ControlPassword`) can read or write
config. Restricted/Add tiers get 401 on `loadconfig`/`saveconfig`. Credentials
live in the Unraid container settings / `nzbget.conf` — **not stored here.**

Useful methods:

| Method | Purpose |
| --- | --- |
| `version` | Sanity/auth check (returns `"26.1"`). |
| `status` | Live runtime state: `DownloadRate`, `DownloadLimit` (runtime speed cap, 0 = unlimited), `*Paused`, `ThreadCount`, free disk. |
| `loadconfig` | Full config **as stored on disk** (array of `{Name,Value}`). |
| `config` | Full config **currently loaded in memory** (may differ from disk until a reload). |
| `saveconfig` | Write config to disk. Takes ONE param: the full `{Name,Value}` array. |
| `reload` | Restart internals to apply saved config (needed for server-connection changes). |
| `log` | Recent log lines — `log(idfrom, nentries)`; great for spotting errors. |

### Safe config-edit pattern (read–modify–write)

`saveconfig` rewrites the whole config from the array you send, so always pull
the full set, change only the keys you want, and write it all back — exactly
what the web UI does:

```python
cfg = call("loadconfig")                    # full array from disk
for o in cfg:
    if o["Name"] == "Server1.Connections":
        o["Value"] = "40"
call("saveconfig", [cfg])                    # note: ONE param = the whole array
call("reload")                               # server-connection changes need a reload
```

**Gotcha — disk vs. memory:** after `saveconfig`, `loadconfig` (disk) shows the
new value but `config` (memory) still shows the old one. Server connection
settings only take effect after `reload`. `reload` drops the RPC connection
briefly while NZBGet restarts (~5–8 s); it does not interrupt the queue if
nothing is actively downloading. Verify with `config` after.

## Incident 2026-06-18 — slow downloads (1–8 Mbit on a gigabit line)

**Symptom:** ~8 Mbit on a good day, 1–2 Mbit otherwise, despite a gigabit line
(client was behind the VPN at the time, but that was not the cause).

**Root cause:** `Server1.Connections = 150`, but the Eweka account
(`news.eweka.nl:563`, SSL) allows only **50 simultaneous connections**. NZBGet
opened 150; Eweka accepted ~50 and rejected the rest. The log was wall-to-wall:

```
[ERROR] Authorization for Eweka (news.eweka.nl) failed: 502 Too many connections
```

The rejected sockets were retried constantly, so the effective pool was a
churn of connect→reject→retry instead of a stable downloading set. That churn —
not a speed limit — produced the erratic, slow throughput. (`DownloadRate=0`
config and `DownloadLimit=0` runtime both confirmed there was **no** speed cap.)

**Fix:** dropped `Server1.Connections` **150 → 50** (Eweka's per-account cap)
via the read-modify-write pattern above, then `reload`. Also enabled
`ArticleCache = 500` (MB) and `WriteBuffer = 1024` (KB), which NZBGet's own
startup warnings recommend. `502 Too many connections` errors stopped instantly.

Tuned **live** against a real 50 GB download (NZBGet `status` polled every 3 s):

| Config | Avg | Peak |
| --- | --- | --- |
| 150 conns (broken) | ~1–8 Mbit/s | — |
| 40 conns | 83 | 92 |
| 40 conns + cache/buffer | 99 | 111 |
| **50 conns + cache/buffer (final)** | **107** | **124** |

~13–15× improvement. The article cache cycled to ~250–400 MB and flushed, never
near the 500 MB cap (no OOM risk).

**Rule of thumb:** `ServerN.Connections` must stay **at or below the provider's
per-account connection limit.** Over-subscribing does not increase speed — it
causes 502 rejections and connection churn that *reduce* it.

**Why 50 is safe here:** NZBGet caps itself at 50 connections *total* across all
its clients, so Sonarr/Radarr feeding this same instance share that pool. The
only thing that would re-trigger 502s is a **separate** downloader (another
SABnzbd/NZBGet) using the same Eweka credentials. This tower NZBGet is the sole
consumer, so 50 is fine.

## VPN path is the real throughput ceiling (2026-06-18)

NZBGet plateaus at ~110–120 Mbit/s even at 50 connections. That is **not** an
NZBGet limit — it is the VPN exit geography.

Usenet traffic is policy-routed (on pfSense) out an **AirVPN exit in Auckland,
New Zealand** (`oceania3.vpn.airdns.org`, exit IP in AS45179 SiteHost NZ). Eweka
is in the **Netherlands**. So every connection runs tower → NZ → NL, a ~280 ms
round-trip. Measured from doc2's VPN-routed NIC (`ens19`, source 192.168.1.36,
the same gateway NZBGet uses):

- VPN tunnel raw capacity (Cachefly anycast, short path): **~216 Mbit/s sustained**.
- VPN **single** TCP connection to Frankfurt/EU: **~10 Mbit/s** (bandwidth-delay
  product over the long NZ→EU leg).

So per-connection throughput to Eweka is latency-capped at a few Mbit; NZBGet
reaches ~120 Mbit only by stacking ~50 of them. The tunnel itself has headroom
(216 Mbit) — the bottleneck is the NZ→NL distance, not the VPN bandwidth.

### pfSense VPN topology (from the pfsense subagent, read-only)

- **Active tunnels (both AirVPN WireGuard):** `tun_wg2`/opt5 → **NZ/Auckland**
  (gateway `AirVPN`, the Usenet path); `tun_wg0`/opt1 → **Singapore** (gateway
  `AirVPN_SG`, configured but unused for Usenet). A `tun_wg1` Mullvad-Perth peer
  exists but has no interface/gateway — orphaned and inert.
- **No European exit exists.** AirVPN offers `eu-nl-*` / `eu-de-*` servers; using
  one needs a new WireGuard tunnel + pfSense interface + gateway.
- **Policy routing:** both `192.168.1.17` (tower/NZBGet) and `192.168.1.36`
  (doc2 ens19) are in the `MV_VPN_IPS` alias → LAN rule routes them via the
  `AirVPN` (NZ) gateway, with a following kill-switch block rule.
- **VPN gateway monitoring is DISABLED** (`monitor_disable=true`) on both
  tunnels — pfSense shows them "online" without probing, so the kill switches
  never auto-trigger and there's no live RTT/loss data.

### Higher-impact levers (not yet done — needs an explicit decision)

The exit location, not NZBGet, is the lever. In rough order of impact/effort:

1. **Re-point Usenet to the existing Singapore tunnel** (`AirVPN_SG`). SG→NL RTT
   (~155 ms) is roughly half of NZ→NL (~280 ms) → roughly double per-connection
   throughput, **zero new infrastructure** (just change the gateway on the
   policy-route rule). Reversible. Changes the exit jurisdiction/IP — a
   privacy/jurisdiction decision, not purely performance.
2. **Add an AirVPN European exit** (`eu-nl` / `eu-de`). ~10–20 ms to Eweka →
   near-line-rate per connection; 50 connections could then saturate the
   tunnel. More setup (new tunnel + interface + gateway + policy route).
3. **Re-enable gateway monitoring** so the kill switch actually works and tunnel
   RTT/loss is visible.

### Unrelated finding: doc2 `192.168.1.35` (ens18) has no internet egress

doc2's default-route NIC times out to all external hosts (DNS resolves, TCP
hangs). pfSense has **no** block/forced-gateway/kill-switch on `.35` — it falls
through to the default WAN gateway. So this is a **doc2 OS-level** issue (ens18
default route / outbound NAT coverage), not a firewall problem. Investigate on
doc2 (`ip route show`, outbound NAT for the full 192.168.1.0/24).

## See also

- NZBGet JSON-RPC reference: <https://nzbget.com/documentation/api/>
- VPN/DNS topology context: `docs/wiki/infrastructure/pfsense-dns-resolver.md`
