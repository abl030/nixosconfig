---
name: plex-media-dmz-containment
description: Plex moved off tower --net=host onto its own VLAN 30 MEDIA_DMZ cage (GitHub #277)
metadata:
  type: project
---

Plex (Docker on **tower**) was moved off `--net=host` onto its own **VLAN 30
"MEDIA_DMZ"** (`192.168.30.2`, gw `.30.1` on pfSense `opt6`) on 2026-06-24 — the
qbt-cage model applied to the one internet-exposed service (GitHub #277). The
firewall is the boundary: pfSense **default-denies `opt6 → RFC1918`** (no fleet/
VLAN reachability), allows **WAN egress only**, forces DNS to `.30.1`, and the
`WAN:11338 → .30.2:32400` forward is **Oceania-gated on the NAT rule itself**.
Container hardened: `--net=br0.30` (Docker ipvlan), `cap-drop=ALL` (+6),
`no-new-privileges`, `UMASK=022`, media mounts **read-only**, template-managed
(autoupdate intact). Caddy `plex.ablz.au` repointed to `.30.2`.

**Casting survives** because cast-device discovery (`_googlecast`, reflected
LAN↔IoT by pfSense Avahi) is between phone and Chromecast — the Plex *server* is
never the discoverer; only the unicast `:32400` stream crosses to the DMZ, which
LAN + IoT are explicitly allowed to reach. Plex "LAN Networks" =
`192.168.1.0/24,192.168.101.0/24` keeps clients on direct play, not Relay.

Gotchas: ipvlan host↔container is blackholed (verify Plex from inside or another
host, not from tower); ipvlan can't ICMP its own gateway (test TCP/DNS); pfSense
Hybrid outbound-NAT needs an explicit `.30.0/24 → wan` entry. Full model +
rollback: `docs/wiki/services/plex-media-dmz.md`. Sibling cage (same model,
AirVPN egress): `docs/wiki/services/servarr-and-qbt-cage.md`.
