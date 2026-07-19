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

## VPN exit geography is the throughput lever (2026-06-18)

On the original NZ exit, NZBGet plateaued at ~110–120 Mbit/s even at 50
connections. That was **not** an NZBGet limit — it was the VPN exit geography
(resolved below: a good NL exit roughly doubled it).

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

### Current pfSense VPN topology (2026-07-19)

- `tun_wg0`/opt1 (`AIRVPN_NL`, internal gateway name `AirVPN_SG`) is pinned to
  Amsterdam server Vindemiatrix. Its data-plane monitor is `1.0.0.1`.
- `tun_wg2`/opt5 (`AIRVPN_US`, internal gateway name `AirVPN`) is pinned to Los
  Angeles server Xamidimura. Its data-plane monitor is `1.1.1.1`.
- `AIRVPN_NL_PREFERRED` uses Netherlands tier 1 and USA tier 2. NZBGet
  `192.168.1.17` is explicitly routed through this group.
- `AIRVPN_US_PREFERRED` uses USA tier 1 and Netherlands tier 2. Other active
  VPN cohorts use this group.
- dpinger actions are enabled and group trigger is packet loss or down state.
  The monitors verify decrypted Internet traffic, not WireGuard handshake age.
- Neither group contains WAN. NZBGet's following kill-switch block remains, so
  failure of both tunnels blocks traffic instead of leaking through the ISP.
- Grafana alerts via Gotify after three minutes of sustained gateway failure.
  Its message describes both USA failover and both-gateway kill-switch blocking,
  and resolves only when the preferred gateway recovers.

### Exit-location experiments → NL wins at ~234 Mbit/s (2026-06-18)

The exit location is the throughput lever, so the Usenet path was moved off NZ.
The spare `AirVPN_SG` tunnel (`tun_wg0`) was the test vehicle; rule 27 pointed at
it; the right AirVPN server roughly **doubled** throughput over NZ.

| Exit (tun_wg0 endpoint) | NZBGet rate | Verdict |
| --- | --- | --- |
| AirVPN NZ `oceania3` (the old default, gw `AirVPN`/tun_wg2) | ~130–155 Mbit/s | prior baseline |
| AirVPN NL `nl3.vpn.airdns.org` (→ `185.200.117.133`) | flat **8.5 Mbit/s** | BAD server — do not use |
| AirVPN NL server `213.152.176.140` | **~234 Mbit/s (peak 247)** | **WINNER — current path** |

**Correction to an earlier hypothesis:** the 8.5 Mbit/s `nl3` result was first
guessed to be an MTU/PMTU blackhole. That was **wrong** — a *different* NL server
at the *same* MTU 1320 does 234 Mbit/s, so `nl3` was simply a bad/congested/lossy
AirVPN node. **Lesson: when an AirVPN exit underperforms, try a different server
IP before blaming MTU** — AirVPN per-server quality varies enormously.

Methodology: ignore CDN speedtests (Cachefly/Linode serve 25-byte block stubs to
AirVPN exits) — bounce NZBGet and read its `status` download rate. NZBGet must be
**reloaded** after any gateway change, because pfSense does not flush states and
existing connections stay pinned to the old gateway until they reconnect.

**Current production path:** NZBGet `.17` → `AIRVPN_NL_PREFERRED` →
`AirVPN_SG`/`tun_wg0` → Vindemiatrix `94.228.209.212:47107`. The observed steady
state public exit after cutover was `94.228.209.215`. If Netherlands fails,
pfSense moves new NZBGet traffic to the USA tunnel automatically. Existing
long-lived connections may need NZBGet reloaded if they do not reconnect by
themselves.

### Unrelated finding: doc2 `192.168.1.35` (ens18) has no internet egress

doc2's default-route NIC times out to all external hosts (DNS resolves, TCP
hangs). pfSense has **no** block/forced-gateway/kill-switch on `.35` — it falls
through to the default WAN gateway. So this is a **doc2 OS-level** issue (ens18
default route / outbound NAT coverage), not a firewall problem. Investigate on
doc2 (`ip route show`, outbound NAT for the full 192.168.1.0/24).

## See also

- NZBGet JSON-RPC reference: <https://nzbget.com/documentation/api/>
- VPN/DNS topology context: `docs/wiki/infrastructure/pfsense-dns-resolver.md`
