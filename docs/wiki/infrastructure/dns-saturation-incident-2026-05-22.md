# DNS saturation incident — 2026-05-22

**Date:** 2026-05-22 (incident) / 2026-05-23 (RCA + fix)
**Status:** Resolved. Tunables applied to pfSense; see [pfsense-dns-resolver](pfsense-dns-resolver.md).
**Trigger:** `rolling-flake-update.service` overnight failure on doc1.
**Surface symptom:** `curl: (6) Could not resolve host: crates.io` inside a Nix build sandbox.
**Real cause:** Chronic pfSense unbound TCP/53 listen-queue saturation; nightly job ran during the visible part of a 24/7 problem.

## What was observed

Nightly `rolling-flake-update.service` on doc1 (22:15 AWST = 14:15 UTC) failed at 14:21 UTC building a single Rust crate fetch:

```
> trying https://crates.io/api/v1/crates/color-spantrace/0.3.0/download
> curl: (6) Could not resolve host: crates.io
```

Cascading failures in jolt → home-manager-path → home-manager-generation. Initial classification labeled it "upstream — wait for crates.io connectivity to be restored."

That classification was wrong. The fleet had a real network DNS outage at exactly 14:18–14:22 UTC.

## The investigation arc (worth the read — the pattern is reusable)

Five passes, alternating between hands-on agents and research:

1. **First-pass RCA from Loki only** (just the rolling-flake-update logs). Concluded: transient crates.io DNS hiccup, no action needed. **Wrong direction.**
2. **Broadened Loki query to all `proxmox-vm` logs** in the window. Found `tailscaled` errors: `dns udp query: waiting for response or error from [100.123.61.111 192.168.1.1]: context deadline exceeded`. Proved pfSense's resolver was the failing point, not crates.io.
3. **Cross-host correlation** showed every fleet host saw the same tailscaled errors simultaneously. Network-wide DNS outage, ~2 minutes hard, with stragglers up to ~11 minutes later.
4. **pfSense subagent investigation** (read-only diags on pfSense itself) found kernel `sonewconn: Listen queue overflow: 193 already in queue` — and confirmed the same overflow fires 15–20 times *per day*. Not an incident — a chronic background problem the nightly job happened to hit during its visible window.
5. **Research subagent** verified upstream defaults and corrected two confident-but-wrong claims from the earlier passes:
   - `kern.ipc.somaxconn` is **not** "bumped to 193" by pfSense — it's bone-stock FreeBSD 128, and 193 is the kernel's internal `× 1.5` ceiling.
   - Initial claim that "tailscaled does DNS over TCP" was *correct empirically* but contradicted Tailscale docs. Research said UDP-only. **A direct check on doc2 settled it:** tailscaled-wrapper holds 4 persistent TCP/53 ESTABLISHED connections to pfSense at idle. Empirical reality wins; docs are wrong (or out of date).

The pattern that worked: **subagent diagnoses → research subagent verifies → loop**. The research pass caught two of my confident assertions that would otherwise have led to wrong fixes.

## Root cause

**pfSense unbound's stock TCP defaults are smaller than our fleet's baseline TCP/53 load.**

The arithmetic:

| | Value |
|---|---|
| Persistent TCP/53 connections from each NixOS host's `tailscaled` | ~4 |
| Active NixOS hosts on the network | ~10 |
| **Required TCP slots (baseline, idle)** | **~40** |
| Unbound `incoming-num-tcp` per thread | 10 |
| Unbound threads | 4 |
| **Available TCP slots** | **40** |

We were sitting at the ceiling 24/7. Any burst — ntopng PTR storm, pfBlockerNG cron, kea2unbound reload on a phone roaming, a large truncated UDP→TCP fallback — pushed us over and the kernel silently dropped new connections.

The 14:18 incident's specific trigger was `kea2unbound` at 14:17:39 reloading unbound after `yoto-mini`'s DHCP lease expired — but it was a final straw, not a cause.

The Nix sandbox needed a non-cached fetch (`crate-color-spantrace-0.3.0.tar.gz`, not yet in our binary cache) and tried to look up crates.io via tailscaled → pfSense → got nothing back → reported "Could not resolve host."

## What we changed

See [pfsense-dns-resolver](pfsense-dns-resolver.md) for the canonical tunables list. Summary:

- `kern.ipc.soacceptqueue: 4096` (was 128) — kernel TCP accept queue ceiling.
- `kern.ipc.maxsockbuf: 16777216` (was 2 MB) — socket buffer ceiling.
- unbound `incoming-num-tcp: 100`, `outgoing-num-tcp: 100` (was 10 each).
- unbound `serve-expired-client-timeout: 1800` (RFC 8767 mode).
- ntopng `--dns-mode: 2` (was 1) on pfSense — removed the loopback PTR storm.

Outstanding (operator action): update pfBlockerNG 3.2.8 → 3.2.15_2+ via GUI to clear the unbound RSS leak.

## What we did NOT change (and why)

- **pfBlockerNG mode** is already on `dnsbl_python` (correct — the older "Unbound mode" causes restart storms).
- **DoT forwarders** (Cloudflare `1.1.1.2` / `1.0.0.2`) are fine — the upstream wasn't broken; we were starving connections to it.
- **Tailscale's TCP-DNS behaviour** — we left this alone. Could file an upstream issue clarifying current behaviour vs docs, but for now we just size pfSense to handle it.

## Lessons

1. **The "upstream is broken" classification is the easiest wrong answer.** Whenever a fetch fails with a DNS error, check our own DNS path before blaming the upstream. The `nix-mirror.ablz.au` substituter kept working through the entire window — that proved doc1 had network, just not DNS for non-MagicDNS names.
2. **Cross-host correlation is cheap and decisive.** Pulling the same time window from `{host=~"doc2|igpu|epimetheus|framework"}` turned a single-host theory into a network-wide finding in one query.
3. **The subagent → research → loop pattern surfaced two wrong assertions** that would have driven wrong fixes. Worth repeating: when a diagnostic finding informs an action, send a research pass before acting if there's any doubt about defaults or upstream behaviour.
4. **Topology blind spots cost time at the start of this session.** "Where does ntopng run?" / "What does tailscaled actually do?" / "What is `100.123.61.111`?" all should have been instant lookups. Added to [CLAUDE.md Network & DNS Topology](../../CLAUDE.md) and this wiki page.
5. **pfSense's system.log and resolver.log do not ship to Loki.** Only filterlog does. For unbound-side debugging, the pfsense subagent or direct SSH is required — Loki searches are a dead end. Worth shipping these eventually; tracked separately.

## References

- [pfsense-dns-resolver](pfsense-dns-resolver.md) — reference page, tunables, restart commands, footguns.
- [Netgate forum #198885](https://forum.netgate.com/topic/198885/pfblockerng-stop-unbound.) — fellow operators with the same `Listen queue overflow: 193`.
- [Redmine #11316](https://redmine.pfsense.org/issues/11316) — pfBlockerNG Python module memory leak.
- [NLnet Labs unbound performance](https://unbound.docs.nlnetlabs.nl/en/latest/topics/core/performance.html) — `incoming-num-tcp` / `outgoing-num-tcp` sizing guidance.
- [RFC 8767](https://datatracker.ietf.org/doc/html/rfc8767) — serve-stale, the standards-compliant mode for `serve-expired-client-timeout`.
