# Incident: prom stopped shipping logs for 29 h (alloy wedged on caddy via wildcard DNS)

**Date:** 2026-06-10 10:08 AWST → 2026-06-11 15:08 AWST (researched 2026-06-11)
**Status:** resolved (alloy restarted); systemic fixes partially applied
**Impact:** ~29 h of `host="prom"` logs dropped from Loki (alloy logged
"no retries left, dropping data" — still in prom's local journald, never
shipped). Second occurrence of this mechanism; first was 2026-05-24.

## Symptom

Gotify `[warning] prom stopped shipping logs to Loki` at 02:23 UTC two nights
running (the second ping was the 24 h re-notify of the same un-resolved alert,
not a new failure). On prom, `alloy` was active but logging every ~1.5 s:

```
final error sending batch, no retries left, dropping data
host=loki.ablz.au status=421 ... 421 Misdirected Request (421): Unknown host
```

## Root cause chain

1. **prom's resolver** is plain `/etc/resolv.conf`: single
   `nameserver 192.168.1.1` (pfSense unbound) + **`search ablz.au`**.
2. **pfSense unbound was thrashing**: 4 GB box, swap 100 % exhausted since at
   least 2026-05-23, unbound OOM-killed near-daily (ntopng + the 4.6 M-domain
   pfBlockerNG DNSBL — see
   [pfsense-dns-resolver](pfsense-dns-resolver.md)). `ablz.au` has **no local
   overrides** on pfSense, so every lookup traverses WAN DoT to Cloudflare —
   under memory pressure some queries SERVFAIL/time out.
3. **Go's resolver walks the search list on *any* failure.** alloy is a Go
   binary; unlike glibc (which only continues on NXDOMAIN), Go's built-in
   resolver in its default lenient mode tries the next search candidate after
   SERVFAIL/timeout too. So a transient failure on `loki.ablz.au.` led it to
   try **`loki.ablz.au.ablz.au.`**.
4. **The public wildcard `*.ablz.au → 192.168.1.6`** (legacy caddy box, exists
   in Cloudflare, so pfSense forwards it) answered that suffixed name.
   The record being "always defined in Cloudflare" is irrelevant — the trigger
   is a failed lookup, and the wildcard converts a transient failure into a
   confidently **wrong** answer.
5. **caddy answers every unknown vhost with `421 "Unknown host"`**, and alloy
   pins its TCP/TLS connection and never re-resolves DNS on a live connection
   (constant retry traffic means it never idles out). Wedged until restarted.

Verification that nailed it: `ss -tnp` on prom showed alloy ESTAB to
`192.168.1.6:443`; `curl --resolve loki.ablz.au:443:192.168.1.6 https://...`
reproduced the exact 421 body; `dig loki.ablz.au.ablz.au` → `192.168.1.6`.
Red herrings ruled out: doc2 nginx restart was 3 h *after* onset and its
access log had zero 421s.

## Recovery

`ssh prom systemctl restart alloy` (the alert runbook). Reconnected to
`192.168.1.35`, ingestion resumed immediately.

## Systemic fixes

- ✅ **2026-06-11: ntopng table caps on pfSense** — frees memory, reduces the
  unbound thrash that causes the trigger blips. Details in
  [pfsense-dns-resolver](pfsense-dns-resolver.md#ntopng-table-caps-memory-diet-2026-06-11).
- ⬜ **Kill or narrow the `*.ablz.au → 192.168.1.6` wildcard** in Cloudflare —
  removes the sticky-failure mechanism. Without it a DNS blip is a
  self-healing 30 s error instead of a silent 29 h wedge. Pending decision on
  what (if anything) still relies on caddy catching unlisted subdomains.
- ⬜ **Local host overrides for `loki.ablz.au` / `mimir.ablz.au` on pfSense** —
  makes observability DNS immune to the WAN forward path.
- ⬜ **alloy 421-watchdog on prom** (`ansible/common/monitoring.yml`) —
  auto-restart on sustained 421s so a recurrence self-heals.

## Lessons

- A `search` domain + a wildcard DNS record + a Go client is a wedge waiting
  for a DNS blip. Audit other Go daemons that dial `*.ablz.au` names from
  hosts with `search ablz.au` (most NixOS fleet hosts resolve via tailscaled
  instead, which doesn't suffix-walk the same way — prom is special because
  it's a bare Proxmox box with a plain resolv.conf).
- When a host "stops shipping logs" but the service is active, check **what
  IP the shipper is actually connected to** (`ss -tnp`) before theorising —
  the stale connection outlives the DNS that created it.
