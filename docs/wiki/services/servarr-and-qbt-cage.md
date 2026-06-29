# servarr host + the qbittorrent microVM cage

**Researched / built:** 2026-06-22 · **Status:** live & working · **Tracking:** Forgejo
[#1](https://git.ablz.au/abl030/nixosconfig/issues/1) (design + build), #8 (indexers),
#9 (dead SG VPN tunnel).

This documents the `servarr` host and the `qbt` qBittorrent microVM that replaced the old opaque
`genericvm` / `Downloader2` Ubuntu KVM. It is **by-agents-for-agents**: architecture, the non-obvious
gotchas, and what to check before touching it. Rules in code live in `hosts/servarr/*` and
`modules/nixos/services/servarr.nix`; this is the *why* and the *traps*.

## What it is

- **`servarr`** — a NixOS VM on **tower** (Unraid), LAN `192.168.1.4` (static via pfSense DHCP
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
   `192.168.1.4 → .20.2:8080` (servarr → qbt WebUI) above a `block LAN → .20.0/24` least-privilege rule.

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

### ⚠️⚠️ The host NFS mount MUST be static — NEVER `x-systemd.automount` (the ESTALE trap)

`/media/data` on servarr is the backing store for the qbt `/downloads` virtiofs share. **virtiofsd
holds open handles into that NFS mount for the life of the qbt VM.** If the mount is an
`x-systemd.automount` (the roaming/laptop pattern from `nfs.nix`), autofs can lazily unmount/remount
it underneath virtiofsd — and virtiofsd's cached handles go **stale**. The guest then sees
`file_open: Stale file handle` (`ESTALE`) and qBittorrent **errors the whole torrent**. Restarting the
torrent in the WebUI does nothing — pause/resume only re-asks libtorrent, while virtiofsd still holds
the same dead handle. Symptom observed 2026-06-26 on the 47 GB "Curb Your Enthusiasm" pack: errored at
~0.4 %, re-errored on restart, **2.3 TB free** (not a space problem) — log showed `ESTALE` on
`Season 3/S03E03…mkv`.

**Fix:** mount `/media/data` via the shared **server** module `homelab.mounts.nfsLocal`
(`mountPoint = "/media/data"; appdata = false; networkdWaitOnline = false`) — the SAME module doc2 uses
for this very export. It is **static** (no automount → no lazy remount → no stale handle), **`hard`**
(I/O blocks-and-resumes across a tower blip instead of erroring), and **`softreval`** (serves cached
attrs during a brief revalidation outage). servarr is a VM *on* tower, so tower is up whenever servarr
boots → a static `_netdev` mount is strictly safer here than autofs. This replaced a hand-rolled inline
`fileSystems."/media/data"` that had copied the laptop automount pattern. **Don't ever re-introduce
`x-systemd.automount` on a server that re-shares the mount over virtiofs.** (`networkdWaitOnline=false`
because NetworkManager owns servarr's LAN and provides `network-online`; networkd here runs only the
IP-less qbt DMZ cage, which never reaches "online".)

**Recovery if it ever does go stale again:** `sudo systemctl restart microvm@qbt.service` on servarr
(abl030 now has passwordless sudo there) — that re-launches virtiofsd with fresh handles; torrent
resume state lives in the persistent `qbt-state.img` volume so it survives. A `homelab.nfsWatchdog.qbt`
(stat-probe `/media/data/Media/Temp` every 10 min → restart `microvm@qbt.service` + Loki alert)
automates this for the residual case (e.g. a tower NFS-server reboot).

**Why it happens at all (the deeper root cause) + the server-side knob:** the stale handle is a
structural Unraid `shfs` (FUSE-union) problem — synthetic, non-stable inodes on `/mnt/user` exports,
governed by the `fuse_remember` timer. Full mechanism, our config, the `fuse_remember` 330→604800 bump
(set 2026-06-26, pending activation at next array start), the "why we can't just export one disk"
(capacity), and the latent cross-disk hardlink caveat:
[../infrastructure/unraid-nfs-shfs-estale.md](../infrastructure/unraid-nfs-shfs-estale.md).

### ⚠️ Boot-race / ESTALE-at-boot after a tower reboot — and the 3 resilience layers (2026-06-29)

The static-mount fix above stops autofs from yanking the mount at *idle*, but a **tower reboot** is a
second, distinct way the same virtiofs handle goes stale — and on 2026-06-29 it stranded qbt for ~1h.

**What happened:** tower rebooted → servarr (a VM *on* tower) rebooted with it. servarr's `/media/data`
NFS mount succeeded fast (07:15:47, only 3 s after attempt), `microvm@qbt` started 3 s later (07:15:50) —
it won the race *by luck*. But tower's `shfs` union was still settling, so the virtiofsd that opened a
handle into `…/Media/Temp` grabbed a soon-to-be-stale inode; tower finished assembling and re-numbered,
the handle went **ESTALE**, and the **guest's `/downloads` mount hung and never completed**. qBittorrent
started anyway (it didn't order after the mount) and ran for an hour against a dead save path. A manual
`systemctl restart microvm@qbt.service` (fresh virtiofsd) fixed it in 2 s.

**Why nothing self-healed — two blind spots:** (1) `microvm-virtiofsd@qbt` only ordered after
`local-fs.target`, **not** the remote-fs NFS mount → it could start before/while the mount was unsettled.
(2) `homelab.nfsWatchdog.qbt` stats `…/Media/Temp` **on servarr**, where the mount was healthy the whole
hour, and `microvm@qbt` stayed `active` — so neither watchdog branch (stale-path / is-failed) could see
that the **guest's** view was wedged.

**The fix — three layers, all in `qbt-microvm.nix` (live 2026-06-29):**
- **A (host ordering):** `systemd.services."microvm-virtiofsd@qbt".unitConfig.RequiresMountsFor =
  "/media/data/Media/Temp"` → virtiofsd (and thus the whole VM) waits for a real, settled mount; closes
  the start-before-mount race. Merges into microvm.nix's per-instance drop-in (`overrideStrategy=asDropin`).
- **B1 (guest fail-fast):** the guest `/downloads` mount gets `x-systemd.mount-timeout=60` (a wedge
  **fails** in 60 s instead of hanging forever), and `qbittorrent.service` gets
  `unitConfig.RequiresMountsFor = "/downloads"` so it **refuses to start** without a real save path
  (never writes to the ephemeral guest root → no lost data/torrent-state).
- **B2 (host guest-health watchdog):** `qbt-health.{service,timer}` (every 5 min, OnBoot 4 min, skips a
  VM active < 3 min so it won't fight a normal boot) probes the qBittorrent WebUI from servarr (pfSense
  allows servarr→`:8080`, `.4` is whitelisted so no creds): if the WebUI is unreachable **or**
  `free_space_on_disk` looks like the guest's sub-GiB tmpfs root instead of the ~1 TB array, it re-rolls
  `microvm@qbt` (fresh virtiofsd) and fires a `warning` Loki alert. This is the layer that *would have*
  auto-fixed the incident — in ~4 min instead of an hour. **This is the canonical recovery now;** the
  manual `systemctl restart microvm@qbt.service` is the break-glass equivalent.

Net: A prevents the bad-handle grab at boot; B1 makes a wedge a crisp failure (qbt down) instead of a
silent one; B2 detects the guest-side wedge the host-path watchdog is blind to and re-rolls automatically.

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

- pfSense: **DHCP static reservation `52:54:00:5e:a1:04 → .4`** (reclaimed from the decommissioned
  downloader2), **Unbound host overrides** `radarr/sonarr/prowlarr/qbt.ablz.au → .4` (these names had
  **no** Unbound override before and resolved to `.4` via external DNS / Cloudflare — which always
  pointed at the intended final `.4`), the `45726` torrent-port forward, and the LAN→qbt `:8080`
  exception pointed at `.4`.
  - **UPDATE 2026-06-28 — servarr IS now in `MV_VPN_IPS`** (reversing the original design below).
    1337x.to banned our home WAN IP (almost certainly from Prowlarr's indexer / Cloudflare-solver
    requests), so `192.168.1.4` was added back to the `MV_VPN_IPS` alias → servarr's internet egress
    now exits via AirVPN (NZ, `AS45179 SiteHost`, e.g. `223.165.69.73`) instead of the home WAN,
    inheriting the existing gateway + kill-switch. A pfSense **floating bypass rule** (src `.4` → dst
    `192.168.20.2:8080`, quick, no gateway) keeps servarr→qbt WebUI direct (cross-VLAN; would otherwise
    be eaten by the `dest=any` MV_VPN_IPS rule). doc2's `vpnClientIPs` mirror re-added `.4` to match.
    Verified live: servarr egress NZ, qbt `:8080`→200, NZBGet `.17`→401. The qbt DMZ guest remains
    separately VPN-caged.
  - *Original design (superseded above): servarr was NOT in `MV_VPN_IPS` — it egressed via the normal
    WAN, and only the qbt DMZ guest was VPN-routed.*
  - *History: the first cutover landed on a temporary `.101` (2026-06-22); the move to the final `.4`
    (2026-06-23) repointed the DHCP reservation, the four Unbound host overrides, and the LAN→qbt rule
    `.101 → .4`, and removed `.4` from `MV_VPN_IPS` (so servarr stops inheriting the old downloader's
    AirVPN kill-switch). doc2's `vpnClientIPs` mirror dropped `.4` to match. Re-added 2026-06-28 (see
    UPDATE above).*
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
- **`/media/data` MUST be a static mount, never `x-systemd.automount`** — autofs remount under
  virtiofsd = `ESTALE` = errored torrents. Uses `homelab.mounts.nfsLocal` (the doc2 server pattern).
  Full writeup in the storage section above ("The host NFS mount MUST be static").
- **A tower reboot can wedge the guest `/downloads` at boot even with the static mount** (virtiofsd grabs
  a tower-`shfs` handle before the share settles → ESTALE → guest mount hangs, VM still "active" so the
  host-path `nfsWatchdog` stays green). Mitigated by 3 layers (A virtiofsd-ordering, B1 guest fail-fast,
  B2 `qbt-health` WebUI watchdog) — see "Boot-race / ESTALE-at-boot" above. If qbt is up but downloads
  are dead after a tower reboot, the canonical fix is now automatic (`qbt-health` re-rolls in ~4 min);
  break-glass is still `sudo systemctl restart microvm@qbt.service`.
- **abl030 has passwordless sudo on servarr** (`security.sudo.extraRules` mkAfter NOPASSWD, hermes-style)
  so the agent can `systemctl restart microvm@qbt.service` etc. from the doc1 bastion without a password
  prompt. servarr is otherwise a normal role="locked" host.

## When to revisit

- Forgejo #9: fix or decommission the dead SG VPN tunnel + add a gateway-down alert.
- Forgejo #8: FlareSolverr for the Cloudflare trackers.
- nicotine-plus → VLAN 20 (`.20.3`) migration (the other Torrent_DMZ tenant) — not yet done.
- First real completed grab will confirm the *arr hardlink end-to-end (perms verified, not yet
  exercised through a full import).
