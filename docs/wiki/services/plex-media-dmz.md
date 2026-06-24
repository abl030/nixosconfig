# Plex on the MEDIA_DMZ (VLAN 30) — least-privilege containment

**Researched / built:** 2026-06-24 · **Status:** live & working, casting + remote verified by the
user · **Tracking:** GitHub [#277](https://github.com/abl030/nixosconfig/issues/277) (inbound-exposed
ports), related least-privilege [#232]. Sibling cage:
[servarr-and-qbt-cage.md](servarr-and-qbt-cage.md) — Plex's containment deliberately **mirrors the qbt
microVM model**: *the firewall is the boundary, not the guest.*

This documents how the Plex Media Server (Docker container on **tower**/Unraid) was moved off
`--net=host` onto its own isolated VLAN so a compromised Plex cannot pivot into the fleet. It is
**by-agents-for-agents**: the architecture, the live config, why casting survives, and the rollback.

## Why

Plex was the **one** port intentionally left open to the internet (WAN `11338` → Plex `:32400`,
GeoIP-gated to Oceania — see #277). The risk was never the media (the library mounts were already
read-only) — it was **lateral movement**: Plex ran on `--net=host`, so the container shared tower's
entire network stack (LAN `192.168.1.2`, `tailscale1`, every VLAN bridge). A single Plex RCE would
have been a stepping-stone onto doc1/doc2/prom/pfSense/the tailnet. *(Remember the LastPass breach — a
popped peripheral that could reach the crown jewels. This closes exactly that path.)*

Goal: family + LAN can reach Plex; **casting keeps working** (a hard user requirement); a popped Plex
can see *nothing* internal and cannot delete media.

## Containment model

| Dimension | How |
|---|---|
| **Network** | Plex has its own IP `192.168.30.2` on **VLAN 30 "MEDIA_DMZ"** (`192.168.30.0/24`, gw `.30.1` on pfSense). pfSense **default-denies it to all RFC1918** (no fleet, no other VLAN), allows **WAN egress** (plex.tv/metadata), forces DNS to the gateway, and forwards `WAN:11338 → .30.2:32400`. Inbound `:32400` is allowed from LAN + IoT clients only. |
| **Disk** | Media mounts are **read-only** (`/mnt/user/data/Media`→`/media3:ro`, the prom NFS music `…Beets`→`/prom_music:ro`). Only `/config` (appdata) is writable. A popped Plex cannot modify/delete media. |
| **Process** | `--cap-drop=ALL` + only the 6 caps the binhex init needs to drop root→nobody, `--security-opt no-new-privileges`, `UMASK=022`. No `--privileged`. |

The difference from the qbt cage: qbt's egress is forced through AirVPN with a kill-switch; **Plex's
egress is plain WAN** (it must reach plex.tv to be useful). Everything else is the same shape.

## Network path (L2)

```
WAN:11338 ─┐
LAN/IoT ───┤  pfSense igc1.30 (opt6, .30.1)  ── igc1 trunk ──► UniFi (auto-tagged VLAN 30)
           │                                                        │
           └──────────────────────────────────────────────► tower Flex-Mini port 4 (trunk)
                                                                    │ eth0.30 → br0.30
                                              Docker ipvlan net "br0.30" ──► Plex 192.168.30.2:32400
```

ipvlan (parent `br0.30`) matches tower's existing pattern (nzbget/nzbhydra2 on the `br0` ipvlan net).
Plex stays **template-managed** (`/boot/config/plugins/dockerMan/templates-user/my-binhex-plexpass.xml`)
so Unraid CA auto-update keeps working — **no image pin** (a hard fleet rule).

## Live config (2026-06-24)

### pfSense (interface `opt6` = MEDIA_DMZ, `192.168.30.1/24`)

Rules on opt6, in order (mirror TORRENT_DMZ but egress = WAN). *Rule IDs drift — match by intent:*
1. block DoT (`:853`)
2. block DoH (→ `pfB_DoH_v4:443`)
3. **pass** DNS: opt6 net → `.30.1:53` (above the RFC1918 block, since `.30.1` ∈ `192.168/16`)
4. **block (log)** opt6 net → `RFC1918` alias (`10/8,172.16/12,192.168/16`) — the containment rule
5. **pass** opt6 net → any (WAN egress via WAN_DHCP)

Supporting:
- **Outbound NAT** `192.168.30.0/24 → wan:ip` (masquerade). pfSense is **Hybrid** outbound-NAT mode, so
  a new subnet does **not** auto-masquerade — without this rule Plex has no internet. (TORRENT_DMZ has
  its own manual `.20.0/24 → opt5/AirVPN` entry; do **not** add an AirVPN entry for `.30`.)
- **DNS redirect (rdr)** `opt6:53 → 127.0.0.1:53` — forces Plex onto pfSense Unbound (Unbound listens
  on "all", so no ACL change was needed).
- **WAN port forward** `11338 TCP/UDP → 192.168.30.2:32400`, **source = `pfB_Oceania_v4`** bound on the
  NAT rule itself (so it's Oceania-gated even if the global WAN GeoIP floating rule is ever
  reordered/removed — defence in depth on top of that floating rule).
- Inbound `:32400`: **LAN** is covered by the LAN catch-all pass; **IoT (opt4)** needed an explicit
  `pass opt4 → .30.2:32400 TCP` placed **above** the IoT egress catch-all (a gateway-override rule
  below it would have routed the cast stream out WAN and dropped it).
- New alias `RFC1918`.

### UniFi

`MEDIA_DMZ` network, **VLAN-only**, VLAN ID 30 (no L3 — pfSense owns it). All trunk ports use
`tagged_vlan_mgmt: auto`, so VLAN 30 was carried to the pfSense uplink and tower port automatically the
moment the network object existed — **no per-port change needed**.

### tower (Unraid)

- `eth0.30` + `br0.30` (persisted in `/boot/config/network.cfg`; the bridge takes **no host IP** — pure
  conduit to pfSense, like `br0.20`).
- Docker network **`br0.30`**: `ipvlan`, subnet `192.168.30.0/24`, gw `192.168.30.1`.
- Plex container changes vs the old `--net=host`:
  - Network `br0.30`, fixed IP `192.168.30.2`.
  - `--security-opt no-new-privileges --cap-drop=ALL --cap-add=CHOWN --cap-add=DAC_OVERRIDE
    --cap-add=FOWNER --cap-add=KILL --cap-add=SETGID --cap-add=SETUID`
  - `UMASK=022` (was `000`).
  - **Unchanged:** both media mounts `:ro`, `/config` rw, `/dev/dri` (GPU transcode), PUID 99 / PGID 100,
    cpuset.

### Plex application

- **Settings → Network → LAN Networks** = `192.168.1.0/24,192.168.101.0/24` (pref key
  `LanNetworksBandwidth`). Because clients are now on a *different* subnet from the server, this stops
  Plex from classifying them as "remote" and routing via Relay — LAN + IoT clients direct-play.
- Remote Access keeps the manually-specified public port `11338`.

### Caddy (`plex.ablz.au`)

`cad` (`192.168.1.6`) `/etc/caddy/Caddyfile` → `…/DotFiles/Caddy/Caddyfile`, stanza repointed
`192.168.1.2:32400` → `192.168.30.2:32400`. Caddy here is **internal-only** (split-DNS + LE wildcard),
not a public ingress, so it doesn't bypass the Oceania gate. The bare `reverse_proxy` is correct for
Plex on Caddy v2 (websockets/streaming auto-handled). `sudo` needs a password on cad — reload via the
admin API instead: `caddy reload --adapter caddyfile --config /etc/caddy/Caddyfile` (localhost:2019,
no root). `caddy validate` run as non-root *fails* reading the root-only LE privkey — that's expected,
not a config error; the reload delegates cert-loading to the running root process.

## Why casting still works (the key insight)

Casting was the make-or-break constraint. It survives the VLAN move because **the Plex server is never
the device that performs cast discovery**:

1. The **phone** discovers the **Chromecast/Google TV** via `_googlecast` mDNS — phone↔cast-device, on
   LAN/IoT. (pfSense already runs an Avahi reflector for `_googlecast._tcp` between LAN ↔ IoT.) The
   server's location is irrelevant here.
2. The phone hands the Chromecast the Plex server URL; the **Chromecast** opens a unicast TCP stream to
   Plex `:32400`.

So the only traffic that has to cross to the relocated server is that unicast `:32400` stream — which we
explicitly allow from both LAN and IoT. No multicast has to traverse the VLAN boundary. (If a cast
*device* ever moves onto VLAN 30, you'd add VLAN 30 to the Avahi `allow-interfaces` list — not needed
today.)

## Verification performed (2026-06-24)

- From inside the container: reaches plex.tv + `.30.1:53` DNS; **cannot** reach doc1 (`.1.29`), prom
  (`.1.12`), or qbt (`.20.2`). Write to `/media3` fails `EROFS`; `/config` writable; prom NFS music
  readable.
- From a LAN host (doc1) and from cad: `GET https://192.168.30.2:32400/identity` returns the
  MediaContainer. `plex.ablz.au` serves through Caddy.
- `docker inspect`: `CapDrop:[ALL]`, `SecurityOpt:[no-new-privileges]`, NetworkMode `br0.30`.
- **User-confirmed:** local direct play, **casting**, remote/family access (off-net), and
  `plex.ablz.au` all working.

## Rollback (≈2 min, fully reversible)

1. tower: revert `my-binhex-plexpass.xml` to `Network=host`, drop the extra params, `UMASK=000`,
   recreate the container. Plex returns to `tower:32400` on host net.
2. pfSense: WAN `11338` target `.30.2 → 192.168.1.2`, source `pfB_Oceania_v4 → any`.
3. Caddy: `plex.ablz.au` upstream `.30.2 → 192.168.1.2`, reload.
   (VLAN 30 / br0.30 / the docker net can stay — harmless when unused.)

## Gotchas (check before touching)

- **ipvlan: the host cannot reach its own container.** tower cannot `curl 192.168.30.2` — verify Plex
  from *inside* (`docker exec`) or from another host (doc1/cad). Nothing on tower needs to reach Plex.
- **ipvlan containers can't ICMP their own gateway** (kernel quirk) — `ping .30.1` fails even though the
  path is healthy. Test reachability with TCP/UDP/DNS (`.30.1:53`), not ping.
- **Hybrid outbound NAT** means new DMZ subnets get no internet until you add an explicit
  `<subnet> → wan` outbound NAT rule.
- **IoT inbound rule ordering** — the cast-stream pass (`opt4 → .30.2:32400`) must sit *above* the IoT
  egress catch-all, or its gateway override black-holes the stream.
- **Moving Plex off `--net=host` instantly kills the old `WAN:11338 → tower:32400` path** (nothing
  binds `:32400` on tower's host IP anymore) — flip the NAT target in the same maintenance window.
- **cad has no passwordless sudo** — reload Caddy via the admin API, not `systemctl`.

## When to revisit

- If you add a second tenant to VLAN 30, add an intra-VLAN block (qbt's template has one) and the Avahi
  reflector interface if it needs cast discovery.
- #277's other item: the two **disabled** AirVPN-NZ P2P forwards (45726/45727) — decide keep/delete.
- Consider narrowing `/dev/dri` cgroup perms from `rwm` to `rw` (mknod not needed) — low priority.
