# Public family-history site (`family.barrett-lennard.com`)

- **Built:** 2026-10-30 · **Tracking:** Forgejo [#250](https://git.ablz.au/abl030/nixosconfig/issues/250),
  phase 6 of `abl030/family-history#137` (plan: `docs/plans/public-export.md` there)
- **Status:** guest, VLAN, firewall and publish path live and verified. The Cloudflare
  tunnel is waiting on a barrett-lennard.com tunnel credential (`tunnelId = null`); reader
  reports email not built yet.
- **Config:** `hosts/doc2/family-public-microvm.nix` (guest), `modules/nixos/services/family-archive.nix`
  (`publicSite`, the doc1 publish command)
- **Related:** [family-archive](family-archive.md) (the private site and LAN preview),
  [slskd-cage](slskd-cage.md) and [plex-media-dmz](plex-media-dmz.md) (the same firewall-is-the-boundary model)

## Design

```text
visitor/agent → Cloudflare edge (TLS, cache, compression, rate limit)
             → outbound tunnel, guest → 198.41.192.0/24|198.41.200.0/24 :7844
             → familypub microVM (doc2), cloudflared → nginx 127.0.0.1:8080
                 root /srv/site/live/current → releases/<UTC stamp>

doc1: family-public-publish
      cp -al preview → snapshot → fh export --check → rsync over SSH
      → pfSense pinhole doc1 → 192.168.22.2:22 → forced command (staging, activate)
```

### Why a Cloudflare Tunnel

Decided with the user on 2026-10-30. barrett-lennard.com is already on Cloudflare in the
same account as ablz.au. The tunnel means no WAN port forward and no published home IP,
so the guest's only egress is Cloudflare's tunnel edge. The edge cache carries repeat
downloads, so a crawler pulling the whole site does not keep using our uplink. TLS ends
at Cloudflare, so the guest holds no certificate and no DNS token, only the
tunnel credential. The costs are that Cloudflare sees all traffic (the site is public
anyway) and that the site depends on its free plan. The fallback, if Cloudflare ever forces
challenges on agents, is a small VPS that doc1 pushes the same tree to.

**Agents must get through.** The site exists for agents (`llms.txt`, dumps, JSON
twins). Zone settings to keep: Bot Fight Mode **off**, "Block AI bots" / AI Crawl
Control **off**, managed robots.txt **off**, security level lowest, plus a WAF skip
rule for `/api/`, `/robots.txt`, `/llms.txt` and `/sitemap.xml`. The rate limit answers 429,
never a challenge page. Verify from outside with plain `curl` and a bot user agent.

### Containment

| Dimension | How |
|---|---|
| Network | VLAN 22 `FAMILY_DMZ` (UniFi vlan-only; pfSense `opt8`, `192.168.22.1/24`, no DHCP). The guest is `192.168.22.2`. doc2 bridges Proxmox VMID 114 `net3` (`ens21`, MAC `bc:24:11:8e:04:3c`, hot-plugged) IP-less to the guest tap. |
| pfSense, FAMILY_DMZ | Rules in order: block DoT and DoH; DNS to `.22.1:53`; UDP 123 to `CF_NTP` (time.cloudflare.com; pfSense runs no ntpd); **block RFC1918**; pass 7844 tcp/udp to `CF_TUNNEL_EDGE` through the `FAMILY_UP` limiter (20 Mbit/s upload); terminal block. Outbound NAT `.22.0/24 → WAN`. No WAN forwards. |
| pfSense, inbound | Floating rules: pass doc1 `192.168.1.29 → .22.2:22`, then block anything to `.22.0/24`, plus blocks on TORRENT_DMZ, Docker VLAN and IoT, whose catch-alls would otherwise match. |
| Host windows | **None.** `storeOnDisk` (its own erofs store, not doc2's `/nix/store`), a 20 GiB volume `/var/lib/microvms/familypub/site.img` (`nodev,nosuid,noexec`), and the tunnel credential as a qemu systemd credential (`credentialFiles`, `/run/credentials/@system/family-tunnel`). No virtiofs. That is also why it is qemu: cloud-hypervisor can't pass credentials. |
| Management | No shell login, Tailscale, fleet key or sops key, and no serial getty. sshd listens on `.22.2` for user `publish` only, whose one key is forced to `family-public-publish-command`. The journal is forwarded to the serial console, so it lands in doc2's `microvm@familypub` journal and Loki. |

The publish key's forced command allows exactly three things:

- `rsync --server …`: `rrsync -wo` into `live/staging` (write-only);
- `activate`: `cp -al staging releases/<stamp>`, an atomic `current` symlink swap, keep three releases;
- `status`: the live release, the release list, and what nginx serves on loopback.

The volume root, which holds the SSH host key, stays root's. The host key is pinned on doc1
(`publicSite.hostKey`); re-pin it if the volume is ever recreated.

### Serving

- nginx on loopback only. gzip on. Per-visitor limits are keyed on `CF-Connecting-IP`,
  because every request arrives from cloudflared: 20 r/s with a burst of 100, 16 connections,
  over-limit answers 429. Access log off; Cloudflare has analytics.
- Cache: pages `max-age=300, s-maxage=86400`; `/o/`, `/images/`, `/api/dump/`
  `max-age=86400, s-maxage=2592000`. Publishing must purge the zone cache once the
  tunnel exists, because the asset URLs carry no version.
- `/o/` keeps the private site's CSP `sandbox`, since it may hold saved third-party pages.
- The site is about 2.4 GB, of which 1.8 GB is downscaled source images (`/o/`). The API is
  51 MB, and its gzipped dumps are 7.2 MB, so an agent wanting the data costs little.

### Map imagery: deliberately not published (2026-10-30)

The user decided against aerial tiles and the basemap for now, as too bandwidth-heavy.
Revisit if the site stays up comfortably. What was settled for later:

- Only manifest layers with `private: false` may go out. On 2026-10-30 these were 1942
  and 1949 (GA/NAA, CC BY 4.0), 1.5 GB. Landgate layers never go out.
- `world.pmtiles` (534 MB, zoom 8) is location-neutral. **`detail.pmtiles` is not**: `fh basemap`
  cuts a box round every located place, private ones included, so it needs a
  public-only cut on the family-history side first.
- The public build passes `FH_BASEMAP=no-basemap` and streams OSM and ArcGIS today.

## Operations

```bash
# on doc1, after a clean export:
cd ~/family-history && bin/fh export --public --out ~/.cache/fh/public-export \
  --serve /var/lib/family-archive/public-site
family-public-publish            # leak-check the snapshot, push, make it live
family-public-publish status     # live release, releases kept, loopback HTTP codes
```

The command refuses to run alongside another publish (flock), and refuses a tree with no
`index.html`. A leak-check failure stops it before anything is uploaded.

**Rollback** to the previous release: there is no shell in the guest by design. Re-publish
the previous export, or temporarily add a `rollback` verb to the forced command.

**Guest logs:** `ssh doc2 'journalctl -u microvm@familypub -f'`.

## Verification

### Isolation probe

`familypub-isolation-probe` runs at boot and daily inside the guest. It TCP-probes
pfSense, doc1, both doc2 addresses, tower NFS, prom, the slskd/qbt/Plex guests,
pfSense's tailnet address, Forgejo and the open internet, all of which must fail. It
requires DNS, including the tunnel SRV record, and the Cloudflare edge on 7844 to work. A breach
fails the unit and logs `ISOLATION BREACH`.

To read the result:

```bash
ssh doc2 'journalctl -u microvm@familypub | grep -E "isolation-probe|BREACH|ISOLATION"'
```

First run, 2026-10-30 13:03: every target blocked; `region1=198.41.192.67`, SRV
`region2.v2.argotunnel.com:7844`; edge reachable; `ISOLATION OK`. Time synced from
`162.159.200.123`.

## Remaining (#250)

1. Cloudflare: create the locally-managed tunnel. Put its credentials JSON in
   `secrets/hosts/doc2/family-public-tunnel.json` and set `tunnelId`. Add a proxied CNAME
   `family → <uuid>.cfargotunnel.com`, a cache rule (cache everything on the host),
   the agent-friendly bot settings above, an edge rate-limit rule, and a cache purge in
   `family-public-publish`.
2. Reader reports address (not built).
3. Kuma monitor on `https://family.barrett-lennard.com/` once live.
