# Mum's site gateway (OpenWrt `mumrouter` → tailnet pinholes)

- **Date:** 2026-10-09
- **Status:** ✅ router on the tailnet; first pinhole (`familysources.ablz.au`) being rolled out.
- **Related:** [tailscale-acl](tailscale-acl.md), [tailscale-share](../services/tailscale-share.md),
  [family-archive](../services/family-archive.md), [raspberrypi-dad-pizero](raspberrypi-dad-pizero.md).

## What it is

Every device on Mum's LAN (`192.168.4.0/24`) can open chosen homelab services without
running Tailscale. Her router runs Tailscale as an **outbound-only gateway**: it
masquerades her LAN onto the tailnet, so the whole house is one tailnet identity
(`mumrouter`, `tag:edge`). The tailnet ACL then grants that identity exact
`tailscaleShare` nodes on TCP 80/443 and nothing else.

```text
Mum's phone/laptop (no Tailscale), DNS via router dnsmasq
  → mumrouter (OpenWrt, tailscale0, fw4 zone "tailscale" masq)
  → tailnet → familysources (tag:share sidecar on doc2, Caddy, one upstream)
  → LAN → https://sources.ablz.au (doc1 nginx, unchanged)
```

Why share nodes rather than a route to doc1: `192.168.1.29:443` serves every
`localProxy` vhost, so an L4 pinhole there would be gated only by the Host header.
A share node has its own IP and serves one upstream, so the ACL is the boundary.
It also means the router needs no `--accept-routes` (which would pull `192.168.4.0/23`,
advertised by `kerrynas`, back over the tailnet and break her LAN).

## The router

- ASUS RT-AX53U, OpenWrt 25.12.5 (`ramips/mt7621`, apk), 248 MB RAM, 35 MB UBIFS overlay.
  `tailscale` 1.98.3 from the signed feed uses ~12.5 MB of overlay (18 MB free after);
  upgrades fit. Install by name (`apk add tailscale`); a fetched `.apk` file is refused
  as untrusted.
- WAN is ISP CGNAT `100.75.48.172/17`. Tailscale's per-peer `/32` routes in table 52
  win over it; no tailnet node sits in `100.75.0.0/17` today.
- Prefs: `tailscale up --hostname=mumrouter --advertise-tags=tag:edge --netfilter-mode=off
  --accept-routes=false --accept-dns=false`. No advertised routes: `kerrynas` still owns
  `192.168.4.0/23`. Tagged node, so no key expiry. Logged in interactively via the
  admin-approved login URL.
- **Admin:** `ssh root@192.168.4.1` from doc1 (key-only use; doc1's
  `master-fleet-identity` key in dropbear `authorized_keys`). doc1 reaches it over the
  `kerrynas` subnet route (doc1's ACL egress is `*`), or over the tailnet at
  `mumrouter:22` (fw4 rule `ts_ssh`, source doc1 only).
- **Firewall (fw4):** `network.tailscale` (`proto none`, `device tailscale0`); zone
  `tailscale`: input REJECT, forward REJECT, output ACCEPT, `masq 1`; forwarding
  `lan → tailscale` only (the pre-existing `tailscale → lan` forwarding was removed).
  Backup of the original: `/etc/config/firewall.pre-tailscale`.
- **DNS:** dnsmasq rebind protection is on. Each shared FQDN is whitelisted with
  `uci add_list dhcp.@dnsmasq[0].rebind_domain='/<fqdn>/'` so the public A record
  (a 100.x tailnet address) is not stripped.

## Adding or removing a service

1. If it has no share node yet, add a `homelab.tailscaleShare.<name>` on doc2
   (`publishIpv6 = false`: fw4 masquerades IPv4 only, so an AAAA would just stall
   Mum's dual-stack clients). Deploy and approve the node's login.
2. Add the node's IP to `hosts` in `tailscale/acl.hujson`, one grant
   `mumrouter → <node>` on `tcp:80`/`tcp:443`, and accept/deny tests. Apply from doc1.
3. On the router: add the FQDN to `rebind_domain`, `uci commit dhcp`,
   `/etc/init.d/dnsmasq reload`.

Remove = delete the grant (and the rebind entry). Revoke everything at once by
removing `mumrouter`'s grants, or `tailscale down` on the router.

## Current pinholes

| FQDN | node | upstream |
|---|---|---|
| `familysources.ablz.au` | `familysources` (doc2) | `https://sources.ablz.au` (family source archive) |

The family archive holds certificates and papers of living people. Sharing it to
every device on Mum's LAN (guests included) was an explicit owner decision on
2026-10-09; no extra auth is in front of it.
