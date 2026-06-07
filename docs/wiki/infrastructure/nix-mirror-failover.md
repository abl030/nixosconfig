# nix pull-through mirror: failover to backup origins

**Date:** 2026-06-07
**Status:** WORKING — deployed on doc1 (proxmox-vm), verified live during the
2026-06-07 Fastly outage.
**Module:** `modules/nixos/nix_caches/nix_cache.nix` (`homelab.cache`)
**Related:** [cratesio-403-ua.md](cratesio-403-ua.md) (the #259 work that surfaced this)

## The incident (2026-06-07)

`nix-mirror.ablz.au` (the pull-through cache on doc1) started returning **502 Bad
Gateway** for every cold path. Root cause was **upstream, not us**:

- `cache.nixos.org` resolves to Fastly's `151.101.{1,65,129,193}.91`
  (`151.101.0.0/16`). From our home WAN **and** from the commercial VPN exit,
  TCP/443 to those IPs **timed out**. Another Fastly range (`199.232.x`),
  github, and `1.1.1.1` were all reachable.
- check-host.net reached `151.101.1.91:443` in 2–42 ms from CA/NL/RU/SG/US, and
  the user's laptop on a **Brisbane** link (different AU ISP) pulled HTTP 200
  from the same IPs. So Fastly was up worldwide — **our ISP's path to that one
  Fastly prefix was broken.** Nothing on our side (no pfSense block: filterlog
  had no drops; WAN showed retried SYNs with no SYN-ACK).

Two second-order problems made it worse:

1. **nginx pinned the upstream IPs at startup.** `proxy_pass https://cache.nixos.org;`
   resolves once at config load and never re-resolves. It had latched onto
   Fastly's (unreachable) **IPv6** addresses — IPv6 is half-configured on the
   fleet (AAAA records returned, no v6 default route), so nginx picked dead
   AAAA upstreams → `no live upstreams`.
2. **No fallback origin.** The mirror's only cold-path source was the dead
   Fastly prefix, so the mirror was exactly as down as cache.nixos.org. The
   mirror is a cache, not an independent copy — mirror-up and mirror-down were
   identical failures for new paths.

Dead ends we ruled out: S3 origin (`nix-cache` bucket is now **Requester
Pays** — anonymous 403); pinning cache.nixos.org to a reachable Fastly edge
(`199.232.x` resets TLS for the cache SNI); routing via the VPN (its upstream
can't reach `151.101` either).

## What we found works

The Chinese university mirrors mirror cache.nixos.org's store and are reachable
from home (AWS/edu prefixes, unrelated to Fastly `151.101`):

- `https://mirror.sjtu.edu.cn/nix-channels/store` — best coverage in testing
- `https://mirror.tuna.tsinghua.edu.cn/nix-channels/store`
- `https://mirrors.ustc.edu.cn/nix-channels/store`

They serve content **signed by `cache.nixos.org-1`** (nix's default-trusted
key), so they are *untrusted-but-verified*: nix checks the signature on every
path client-side, so a hostile mirror cannot inject bad store paths — worst case
is a failed sig check. Speed from China to AU is ~2 MB/s.

## The fix (Option A — failover inside the mirror)

`nix_cache.nix` now generates a per-store-area failover chain
(`@fetch_<narinfo|nar|nixcacheinfo>_<i>`):

```
try_files (disk)  ->  cache.nixos.org  ->  SJTU  ->  TUNA
```

Key mechanics:

- **`error_page 502 503 504 = @fetch_..._<next>`** fails through on connection
  error / timeout / 5xx — **not** on 404. A 404 (path genuinely not cached)
  returns to the client so nix builds from source instead of hammering every
  mirror.
- **`proxy_pass https://<host><prefix>$request_uri;`** carries the URI so nginx
  resolves the host **per request** via `resolver`, killing the stale-pinned-IP
  bug. `$request_uri` (not `$uri`) is used because gixy flags `$uri` in
  proxy_pass as http-splitting (it can contain decoded `\n`); `$request_uri` is
  the raw request line and is safe. The fallback path prefix
  (`/nix-channels/store`) lives in the proxy_pass target.
- **`resolver 100.100.100.100 valid=300s ipv6=off;`** — Tailscale MagicDNS,
  A-records-only. `ipv6=off` is the direct fix for "nginx latched onto dead
  AAAA upstreams."
- **`proxy_store on`** writes to `root + $uri` (the location's internal URI,
  independent of the proxy_pass target), so a path pulled from China is cached
  to doc1's disk in the canonical layout and served fast (~10 ms) to the whole
  fleet thereafter — the slow China pull happens **once**.
- **`proxy_next_upstream_tries 2` + `proxy_connect_timeout 3s`** cap how long a
  dead primary stalls before failover. cache.nixos.org has 4 A records;
  unbounded, nginx tried all four at 5 s each = ~20 s per cold path. Now ~6–7 s.
  `proxy_read_timeout 300s` covers large NARs over the slow fallback link.

Fallbacks/resolver are tunable: `homelab.cache.mirrorFallbacks` (list of
`{host, prefix}`) and `homelab.cache.mirrorResolver`.

## Verified (live, during the outage)

| Test | Result |
|------|--------|
| `/nix-cache-info` via mirror | 200 (failover → SJTU) |
| cold `.narinfo` via mirror | 200, signed by `cache.nixos.org-1`, stored to disk |
| cold `.nar.xz` via mirror | 200, correct bytes, stored to disk |
| repeat (disk hit) | ~10 ms |
| cold-path latency during outage | ~6.7 s (was ~20 s / hang) |
| `nix path-info --store https://nix-mirror.ablz.au <path>` | accepted at nix layer |
| build-time `gixy` + `nginx -t` | pass |

## Caveats / when to revisit

- **Channel lag:** SJTU/TUNA track the released *channel* store, which trails
  `nixpkgs-unstable` by a few days. During an outage, freshly-bumped paths may
  404 on the fallbacks and build from source. The failover covers the bulk of
  stable nixpkgs, not the bleeding edge. (We don't chain on 404 — see above.)
- **Normal operation is unaffected:** when Fastly is reachable the primary
  answers in ~50 ms and the fallbacks are never touched.
- If the China mirrors ever become unreliable, edit `mirrorFallbacks`. The
  signature check means adding a new public mirror is low-risk.
- Revisit if upstream nixpkgs adds a sanctioned multi-origin substituter story,
  or if we stand up our own geographically-diverse origin.
