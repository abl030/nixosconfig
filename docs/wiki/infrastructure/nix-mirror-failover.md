# nix pull-through mirror: failover to backup origins

**Date:** 2026-06-07
**Status:** WORKING — deployed on doc1 (proxmox-vm), verified live on 2026-06-07
while cache.nixos.org was unreachable from the fleet.
**Module:** `modules/nixos/nix_caches/nix_cache.nix` (`homelab.cache`)
**Related:** [pfblockerng-fastly-block-incident-2026-06-07](pfblockerng-fastly-block-incident-2026-06-07.md)
(the outage this was built/verified against — read it for the *actual* root
cause), [cratesio-403-ua.md](cratesio-403-ua.md) (the #259 work that surfaced this).

## Why this exists

On 2026-06-07 `cache.nixos.org` became unreachable from every fleet host —
`nix-mirror.ablz.au` returned `502 Bad Gateway` for every cold path, and the
fleet could not fetch any new store path. The mirror is a *cache, not an
independent copy*: its only cold-path origin was cache.nixos.org, so when that
was unreachable the mirror was exactly as down as the upstream. **Mirror-up and
mirror-down were identical failures for new paths.** That single-origin fragility
is what this change fixes.

> **Important — what the outage actually was:** it was *not* an ISP/Fastly fault,
> even though it was confidently diagnosed as one for hours. The real cause was a
> **pfBlockerNG false-positive** blocking Fastly's `151.101.0.0/16` at our own
> firewall. Full story + the diagnostic lesson:
> [pfblockerng-fastly-block-incident-2026-06-07](pfblockerng-fastly-block-incident-2026-06-07.md).
> The failover below is origin-cause-agnostic: it protects against *any* reason
> the primary origin is unreachable (feed false-positive, real ISP fault, Fastly
> regional issue, …), which is exactly why it's worth keeping regardless of the
> mis-call.

A confounding factor seen early (independently worth fixing): nginx's
`proxy_pass https://cache.nixos.org;` resolves the name **once at startup** and
never re-resolves, and it had latched onto Fastly's **IPv6** addresses (AAAA
returned, but IPv6 is half-configured on the fleet — no v6 default route) →
`no live upstreams`. The resolver/`ipv6=off` change below fixes that for good.

Dead ends ruled out while chasing the (wrong) upstream theory, kept for
posterity: S3 origin (`nix-cache` bucket is now **Requester Pays** — anonymous
403); pinning cache.nixos.org to a reachable Fastly edge (`199.232.x` resets TLS
for the cache SNI); routing via the commercial VPN (couldn't reach `151.101`
either — because the *same* pfBlockerNG rule blocks LAN→those-IPs regardless of
egress path).

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
