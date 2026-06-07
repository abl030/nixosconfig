# pfBlockerNG blocked cache.nixos.org (Fastly) — incident 2026-06-07

**Date:** 2026-06-07 (incident, diagnosis, fix — same morning)
**Status:** RESOLVED. `151.101.0.0/16` suppressed in pfBlockerNG; fleet access to cache.nixos.org restored. Failover hardening landed alongside (see [nix-mirror-failover](nix-mirror-failover.md)).
**Trigger:** pfBlockerNG IP-reputation feed update flagged Fastly anycast IPs.
**Surface symptom:** every fleet host's Nix builds 502/timed out on cold paths; `nix-mirror.ablz.au` returned `502 Bad Gateway`.
**Real cause:** pfBlockerNG's `pfB_PRI4_v4` deny table contained the four cache.nixos.org Fastly IPs as `/32`s (Project Honeypot feed false-positive). pfSense was dropping the fleet's traffic to them.
**Misdiagnosis:** for several hours this was confidently (and wrongly) called an upstream ISP→Fastly routing fault. See the investigation arc — the lesson is the reusable part.

## What was observed

`nix-mirror.ablz.au` (the pull-through cache on doc1) started returning `502 Bad
Gateway` for every cold path. From every LAN host, TCP/443 to cache.nixos.org's
Fastly IPs **timed out** (no SYN-ACK):

- `151.101.1.91`, `151.101.65.91`, `151.101.129.91`, `151.101.193.91` (`151.101.0.0/16`)

`traceroute` to `151.101.1.91` died immediately after the gateway
`192.168.1.1` (pfSense), no further hops.

## The investigation arc (worth the read — the misdiagnosis is the lesson)

1. **First pass: blamed the nginx mirror.** nginx logs showed `no live upstreams`
   connecting to `https://cache.nixos.org`. The cached upstream IPs were
   **IPv6** (`2a04:4e42::`), and IPv6 is half-configured on the fleet (AAAA
   returned, no v6 default route). Disabled IPv6 + restarted nginx so it
   re-resolved to IPv4 → still failed, now with v4 timeouts. **IPv6 was a red
   herring.**
2. **Pass two: "it's the network, and it's Fastly-specific."** TCP to the four
   `151.101.x.91` IPs timed out, but another Fastly range (`199.232.36.49`),
   github, and `1.1.1.1` were all fine. Reproduced identically on doc2 → fleet-wide.
3. **Pass three: "Fastly is up, so it must be our ISP's route."** check-host.net
   reached `151.101.1.91:443` in 2–42 ms from CA/NL/RU/SG/US/HK; the user's
   laptop on a **Brisbane** link (different AU ISP) pulled HTTP 200 from the same
   IPs; even the commercial VPN exit (`223.165.69.73`) couldn't reach them.
   **Confident — and wrong — conclusion: an ISP↔Fastly peering fault for
   `151.101.0.0/16`.** Ruled out a pfSense block too hastily: filterlog (shipped
   to Loki) showed no drops for these IPs, and the WAN showed `pass,out` SYNs.
4. **Built failover hardening** on that premise (mirror falls over to Chinese
   university mirrors — still valuable, see [nix-mirror-failover](nix-mirror-failover.md)).
5. **The user didn't buy it** ("this is wild, I still can't believe it") and
   asked the pfSense subagent to confirm it was not our end. The **single test
   nobody had run — reachability from pfSense itself — settled it in one shot:**
   pfSense pings `151.101.1.91` at 14 ms, 0% loss. If the firewall can reach it
   but LAN clients cannot, it was *never* the ISP.

The pfSense subagent then found all four IPs sitting in the `pfB_PRI4_v4` pf
table with a `block quick` rule that had dropped ~111k packets.

## Root cause

pfBlockerNG's **Project Honeypot** IP-reputation feeds (`HoneyPot_IPs_v4`,
`HoneyPot_Mal_v4`) had flagged the four cache.nixos.org anycast IPs as
individual `/32` malicious hosts and merged them into the `pfB_PRI4_v4` deny
table. The relevant pf rules:

```
block drop   quick on igc0 inet from <pfB_PRI4_v4> to any   # WAN inbound: drops return traffic FROM these IPs
block return quick on igc1 inet from any to <pfB_PRI4_v4>   # LAN outbound: blocks traffic TO these IPs
```

This is a classic CDN false-positive: Fastly serves thousands of unrelated
sites from each shared anycast IP, so a single compromised tenant gets the whole
IP onto a reputation feed — and cache.nixos.org happened to share `151.101.x.91`.

**Why the symptom was a timeout, not "connection refused":** `block return`
would normally RST the outbound SYN. The observed timeouts (nginx logged
`upstream timed out`) are most consistent with the **WAN-inbound `block drop`**
dropping the SYN-ACK whose source is a blocked IP — the SYN goes out, the reply
is silently dropped, the client waits. Either way the packets die at pfSense.

**Why `199.232.x` worked:** not in `pfB_PRI4_v4` (`pfctl ... -T test` → `0/1`).
Different Fastly range, not flagged by the feeds.

**Why pfSense itself could reach it:** pf is stateful — pfSense's own outbound
connection creates a state, and the reply matches that state and is passed
before the block rule is evaluated for a new connection.

## The fix

Whitelist the **entire Fastly `151.101.0.0/16`** in pfBlockerNG (suppressing
individual IPs is whack-a-mole; the feeds keep re-flagging). Applied by the
pfSense subagent:

- Added `151.101.0.0/16` to pfBlockerNG **IP Suppression**
  (`config.xml` → `installedpackages/pfblockerngipsettings`, base64-encoded;
  written to `/var/db/pfblockerng/pfbsuppression.txt`).
- Removed the four IPs from the live table and the alias file so a reload
  wouldn't re-add them: `pfctl -t pfB_PRI4_v4 -T delete <ips>` and purged
  `/var/db/aliastables/pfB_PRI4_v4.txt`.
- **Force Update / Force Reload** so future feed runs respect the suppression.
- **Did NOT flush firewall states** (house rule — see CLAUDE.md / memory).

**Verified after fix (from doc1 / LAN):** all four IPs `OPEN`; direct
`cache.nixos.org` → HTTP 200; mirror → HTTP 200 in ~50 ms (back on primary, no
failover). `pfctl -t pfB_PRI4_v4 -T test 151.101.1.91 ...` → `0/4 match`.

## Operational reference: pfBlockerNG IP suppression

- **Deny tables** are pf tables named `pfB_*` (e.g. `pfB_PRI4_v4`). Inspect:
  `pfctl -t pfB_PRI4_v4 -T show` / test membership: `pfctl -t <tbl> -T test <ip>`.
- **Which feed flagged an IP:** grep `/var/db/pfblockerng/deny/*.txt`.
- **Suppression (allowlist):** `/var/db/pfblockerng/pfbsuppression.txt` (IP/CIDR
  per line). The authoritative copy is in `config.xml` under
  `installedpackages/pfblockerngipsettings` (`v4suppression`, base64). Add the
  CIDR there + Force Reload; editing only the pf table is not persistent.
- Prefer suppressing the **owning CIDR/ASN** (here: Fastly `151.101.0.0/16`,
  AS54113) over individual `/32`s.
- pfBlockerNG **DNSBL** (domain blocking) is a *separate* mechanism — those show
  up as `app="unbound"` `[pfBlockerNG]` in Loki. This incident was **IP**
  blocking, which does not necessarily log to filterlog with these rules.

## Lessons (reusable)

1. **To tell "our end" from "the ISP": test from the firewall itself.** If
   pfSense can reach a destination that LAN clients can't, the fault is between
   pfSense and the LAN (rule / NAT / pfBlockerNG / policy route) — not upstream.
   This one test would have skipped hours of ISP theorising. Add it to the *first*
   pass, not the last.
2. **"Reachable from the whole world but not from us" does not imply the ISP.**
   A local deny rule produces exactly that signature. Global reachability only
   rules out the *remote* end being down; it says nothing about our own egress.
3. **Absence of filterlog drops ≠ no firewall block.** pfBlockerNG IP rules may
   not be logging; verify against the pf tables directly, not just logs.
4. **Reputation feeds false-positive CDN anycast IPs.** When a single IP inside
   a big CDN range (Fastly/Cloudflare/Akamai) becomes unreachable while the rest
   of the internet is fine, suspect a local IP blocklist before the ISP.
5. The failover hardening built on the wrong premise was **still worth keeping** —
   it protects against *any* cause of an origin being unreachable, this one
   included.
