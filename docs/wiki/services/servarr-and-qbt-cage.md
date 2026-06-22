# servarr host + the qbittorrent microVM cage

**Researched / built:** 2026-06-22 · **Status:** live & working · **Tracking:** Forgejo
[#1](https://git.ablz.au/abl030/nixosconfig/issues/1) (design + build), #8 (indexers),
#9 (dead SG VPN tunnel).

This documents the `servarr` host and the `qbt` qBittorrent microVM that replaced the old opaque
`genericvm` / `Downloader2` Ubuntu KVM. It is **by-agents-for-agents**: architecture, the non-obvious
gotchas, and what to check before touching it. Rules in code live in `hosts/servarr/*` and
`modules/nixos/services/servarr.nix`; this is the *why* and the *traps*.

## What it is

- **`servarr`** — a NixOS VM on **tower** (Unraid), LAN `192.168.1.101` (static via pfSense DHCP
  reservation), MAC `52:54:00:5e:a1:04`. Runs the **\*arr trio** (radarr/sonarr/prowlarr) as native
  `services.*` behind nginx/localProxy (`{radarr,sonarr,prowlarr,qbt}.ablz.au`, never by IP). Locked
  fleet host (no passwordless sudo, root SSH off, **not** a tailnet node — reachable on LAN + via
  tower's subnet route). `homelab.services.servarr` module.
- **`qbt`** — a nested **`microvm.nix` / cloud-hypervisor** guest *inside* servarr. The ONE
  hostile-input box (internet-facing libtorrent), so it gets VM-grade isolation. `192.168.20.2` on
  its own VLAN. Config: `hosts/servarr/qbt-microvm.nix`.
- Replaced **`genericvm`** (= libvirt dom `Downloader2`, Ubuntu, `192.168.1.4`): radarr/sonarr/
  prowlarr + Deluge. Now **decommissioned** (services `disable --now`'d, VM shut down, kept as a stale
  rollback). Usenet client **NZBGet @ `192.168.1.17`** and **Prowlarr→Readarr @ tower `192.168.1.2:8787`**
  were untouched and carried over.

## The qbt cage (network)

The **firewall is the boundary, not the guest.** qbt is on **VLAN 20 "Torrent_DMZ"** (pfSense
`opt2`, `192.168.20.0/24`, gw `.20.1`). The data path is pure L2: qbt tap → `br-dmz` on servarr →
servarr's 2nd vNIC `enp2s0` → tower `br0.20` → `eth0.20` → switch (trunked) → pfSense `igc1.20`.
servarr itself takes **no IP** on VLAN 20 (pure conduit); networkd owns `br-dmz`/uplink/tap,
NetworkManager owns the LAN NIC.

pfSense `opt2` rule chain (egress is VPN-only):
1. block DoT(853)/DoH · **PASS DMZ→`.20.1:53`** (DNS — see gotcha) · block →LAN/Docker/IoT/intra-VLAN/`10/8`
2. **PASS opt2-net → any via the AirVPN NZ gateway** (`opt5`/`tun_wg2`) · **kill-switch BLOCK** (tunnel
   down = drop, never leak). Plus outbound NAT `.20.0/24 → opt5`, a DNS redirect (`:53 → 127.0.0.1:53`),
   the inbound forward `opt5:45726 → .20.2:45726` (torrent port), and ONE LAN exception
   `192.168.1.101 → .20.2:8080` (servarr → qbt WebUI) above a `block LAN → .20.0/24` least-privilege rule.

Verified egress is the AirVPN NZ exit IP (qbt's `Detected external IP` = the tunnel; DHT live).

## ⚠️ The qbt STORAGE gotcha chain (virtiofs-over-NFS) — the hard one

qbt's `/downloads` is a **virtiofs share of an NFS-backed scratch** (`/media/data/Media/Temp`, the
tower NFS library, so the *arr can **hardlink** completed files into the library on the same fs). The
guest can't NFS-mount tower directly (cage), so servarr re-shares it over virtiofs. libtorrent then
failed with a *cascade* of "Operation not supported" / "Permission denied" — each layer fixed in turn
(all in `hosts/servarr/qbt-microvm.nix` + `modules/nixos/services/servarr.nix`):

1. **`file_stat: Operation not supported`** — Unraid NFS supports **neither POSIX ACLs nor user
   xattrs** (both `EOPNOTSUPP` — test with `python3 -c 'import os; os.setxattr(...)'`), but
   **microvm.nix HARDCODES `--posix-acl --xattr`** on virtiofsd. Fix: override
   `microvm.virtiofsd.package` (a **guest-side** option, set inside `microvm.vms.qbt.config.microvm`)
   with a `writeShellScriptBin "virtiofsd"` wrapper that **strips those two flags** and execs the real
   one. (Keep `inode-file-handles=prefer` — that's the fd-exhaustion fix, see
   `infrastructure/virtiofsd-fd-exhaustion.md`.)
2. **`file_open: Permission denied`** — scratch dir is `99:100` (`users`, mode `2775`/setgid). qbt ran
   under its own gid. Fix: `services.qbittorrent.group = "users"` (virtiofs passes the guest egid
   through to the backend).
3. **write fails (file created `0644`, group-read-only)** — the NFS **squashes qbt's uid to 99**, so
   qbt re-opens its OWN files via **gid 100 (group)**; default umask `022` → `0644` = group-read-only.
   Fix: `systemd.services.qbittorrent.serviceConfig.UMask = "0002"` → `0664` group-writable.
4. **\*arr hardlink import** — the *arr run as `media` (gid 998) but the downloads are gid 100. Fix:
   add radarr/sonarr to the **`users`** group (gid 100) so `fs.protected_hardlinks` lets them link
   files they can group-write.

Result: cage stays intact (no NFS pinhole), qbt writes `0664 99:100` files, *arr hardlink them out.
**A pre-existing 0-byte `0644` partfile blocks a re-add** (the umask only affects *new* files) — `rm`
stale files from the scratch (via the guest agent / `99` owner) when testing.

## Migration (data)

The migration that works (per app; do it with **both** source+dest *arr stopped for a consistent DB):
- **Data dirs are NOT `/var/lib/<app>`.** radarr → `/var/lib/radarr/.config/Radarr/`, sonarr →
  `/var/lib/sonarr/.config/NzbDrone/` (legacy "NzbDrone"!), **prowlarr → `/var/lib/prowlarr/`
  directly** but it's a systemd **DynamicUser** (state at `/var/lib/private/prowlarr`, uid 61654 only
  exists while running → `chown 61654:61654`, not `prowlarr:prowlarr`).
- Copy `config.xml` + `<app>.db` (+ `-wal`/`-shm` if the source didn't checkpoint), set
  `BindAddress=127.0.0.1`, chown (`radarr:media`/`sonarr:media`/`61654:61654`). **Also copy
  `MediaCover/`** (the poster cache, ~2 GB) or thumbnails 404 until re-fetched. Version compat: a
  `develop`-branch source DB migrates forward fine into nixpkgs radarr 6.x / sonarr 4.x.
- ApiKeys carry over (so overseerr + Prowlarr links keep working). Download clients: re-point the old
  Deluge → **qBittorrent @ `192.168.20.2:8080`** + a **Remote Path Mapping** `/downloads/ →
  /media/data/Media/Temp/` (qbt reports `/downloads`, servarr sees the NFS path); NZBGet @ `.17:6789`
  unchanged. WebUI auth: qbt uses an `AuthSubnetWhitelist` (pfSense already gates who reaches `:8080`).
- *arr API is reachable as `abl030` over loopback with the key (no root needed) — handy for scripting.

## Cutover

- pfSense: DHCP-pin `.101`, add **Unbound host overrides** `radarr/sonarr/prowlarr/qbt.ablz.au → .101`
  (these names had **no** Unbound override before and resolved to `.4` via external DNS), enable the
  `45726` forward, point the LAN→qbt rule at `.101`.
- **ACME:** first deploy left a **minica self-signed** cert (the Cloudflare token wasn't decryptable
  pre-sops-bootstrap, so the `acme-order-renew-*` units failed with "dependency"). After the token
  lands, **restart `acme-order-renew-<name>.service`** to fetch the real LE certs, then `reload nginx`.
- Decommission genericvm: `systemctl disable --now` its services, `virsh shutdown Downloader2`.

## Gotchas index (check before touching)

- **Don't over-allocate the servarr VM RAM** — it OOM-killed at 6 GiB on tower (working set ~1.3 GiB,
  capped to 4 GiB). A Linux VM fills its allocation with page cache → host RSS = allocation under I/O →
  OOM (no swap on tower; also starves Plex). See `.claude/agents/tower.md`.
- **microvm.nix does NOT restart the qbt VM on `nixos-rebuild switch`** — `systemctl restart
  microvm@qbt.service` after a qbt config change. Confirm with `/var/lib/microvms/qbt/{current,booted}`.
- **`MV_VPN_IPS` must point at a HEALTHY gateway.** Today's VLAN-20 work left that rule on the **dead
  AirVPN Singapore tunnel** → NZBHydra2 (`.18`) + NZBGet (`.17`) + all MV_VPN_IPS hosts had 0 egress
  (kill-switch dropped them) = the "Usenet broken / no results" outage. Fixed to AirVPN NZ; Forgejo #9.
- **DMZ DNS:** qbt's resolver is `.20.1`, but the intra-VLAN-isolation block (`block → .20.0/24`,
  qbt↔nicotine) also matches `.20.1` → silently drops DNS. Needs an explicit **pass `opt2 → .20.1:53`
  above** that block (else DHT/trackers fail with "Host not found", 0 DHT nodes).
- **Indexers:** public torrent trackers behind Cloudflare (1337x, EZTV) need **FlareSolverr** (none
  configured); some have dead Cardigann definitions (HTTP 500). 5 were disabled, 7 work (Forgejo #8).
  The migrated Prowlarr/\*arr DBs carry **inherited failure-backoff** that masks which actually work —
  a calm per-indexer test reveals the truth.
- **No POSIX-ACL/xattr on the NFS** is a general trap for anything virtiofs-ing an Unraid NFS share.

## When to revisit

- Forgejo #9: fix or decommission the dead SG VPN tunnel + add a gateway-down alert.
- Forgejo #8: FlareSolverr for the Cloudflare trackers.
- nicotine-plus → VLAN 20 (`.20.3`) migration (the other Torrent_DMZ tenant) — not yet done.
- First real completed grab will confirm the *arr hardlink end-to-end (perms verified, not yet
  exercised through a full import).
