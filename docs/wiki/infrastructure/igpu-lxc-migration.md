# igpu: VFIO passthrough VM → unprivileged NixOS Proxmox LXC

**Status:** PLANNED / prep staged (2026-06-29). Cutover blocked on one `prom` reboot.
**Owner action required:** pick a maintenance window (a `prom` reboot bounces the
whole fleet — doc1, doc2, igpu, hermes, HA all restart).

Supersedes the long-standing iGPU reset-bug workaround documented in
[`igpu-passthrough.md`](./igpu-passthrough.md) (line 55: *"if we switch to a
hardware reset mechanism, revisit this"* — this **is** that resolution).

---

## TL;DR

The AMD **Raphael** iGPU (`1002:13C0`, RDNA2, in the 9950X) cannot be reliably
reset under VFIO. We move the four GPU workloads off the passthrough VM into an
**unprivileged NixOS LXC** on `prom`, where the **host** binds `amdgpu` once at
boot and the container bind-mounts `/dev/dri/renderD128`. No vfio, no
vendor-reset, no PSP reset — the failure class becomes structurally impossible.

The `prom` reboot is the single cutover event: it clears the currently-wedged PSP
**and** hands the iGPU to the host's `amdgpu`.

---

## Why (root cause — see also the reset research)

- The repo runs a **kludged** `vendor-reset`: `ansible/prom_prox/patch_igpu_reset_PVE9.yml`
  + `templates/device-db.h.j2` map `1002:13c0` onto vendor-reset's **`_AMD_NAVI10`**
  list (`amd_navi10_ops`), because Raphael has no real entry. This runs the
  **Navi10 / SMU-11 / PSP-11** reset sequence against Raphael's **SMU-13 / PSP-13**
  silicon.
- Symptom: the foreign SMU messages are never acknowledged (`SMU error 0x0`,
  ~20 s `wait for MP1` stalls); vendor-reset reports `mode1 reset succeeded` anyway
  and returns, leaving the PSP half-reset. After a few VFIO reset cycles the PSP
  **wedges permanently**: guest `amdgpu` then fails every boot with
  `psp reg (0x16080) wait timed out … PSP firmware loading failed →
  hw_init of IP block <psp> failed -22 → amdgpu probe -22`. No `/dev/dri/renderD128`.
- **Confirmed not software-recoverable:** binding the iGPU to `amdgpu` on the
  **host** fails identically (`-110` ETIMEDOUT), firmware present. Only a cold
  power-cycle (host reboot) clears the PSP.
- **The correct Raphael reset (mode2) lives only inside the `amdgpu` driver**
  (`smu_v13_0`/`psp_v13_0`) and is reachable only while `amdgpu` is bound; it is
  *not* in the kernel PCI reset-quirk table, so `vfio-pci` can't call it, and
  `vendor-reset` never ported it. → Under VFIO there is no correct reset for this
  chip. Under LXC, `amdgpu` stays bound on the host and the GPU is never reset.

(Full feasibility research, incl. the LXC mechanics, was captured in the session
that produced this doc.)

---

## Target architecture

```
prom (Proxmox 9.2.3, host kernel binds amdgpu to 1002:13C0 once at boot)
 └─ /dev/dri/renderD128   (root:render, char 226:128)
     │  dev0 passthrough (gid=303,mode=0660)
     ▼
  CT <id> "igpu"  — UNPRIVILEGED NixOS LXC, IP 192.168.1.33
    ├─ jellyfin            (native)  VAAPI  → renderD128   (render group)
    ├─ whisper-server      (native)  Vulkan radv → renderD128
    ├─ mailsearch.embed    (native)  Vulkan radv → renderD128
    └─ tdarr-node          (rootful podman) VAAPI → renderD128  (nesting/keyctl/mknod)
```

**Key fact:** none of the four need `/dev/kfd` (ROCm). VAAPI (radeonsi) and Vulkan
(radv) both go through the single `renderD128` node — so a single device
passthrough covers all four, and the "AMD needs a privileged CT" folklore (which is
about ROCm/kfd) does **not** apply.

### Isolation decision: UNPRIVILEGED (reject privileged)

- VFIO VM (today): separate guest kernel — strongest isolation, but the reset bug.
- **Unprivileged LXC (chosen):** shares prom's kernel, but CT-root is remapped to an
  unprivileged host UID; escape needs a kernel LPE, not just CT-root.
- Privileged LXC (**rejected**): CT-root *is* host UID 0 → one escape = root on the
  hypervisor = whole fleet. Violates the repo least-privilege rule (CLAUDE.md).

This migration is *already* an isolation step-down (VM→container); unprivileged is
where we stop. tdarr-node stays **rootful podman** (the repo's `homelab.podman`
model) — rootful sidesteps the rootless subuid/idmap morass in an unprivileged CT.

---

## Storage re-plumbing (the meaty part)

The igpu VM today layers **three** sources with `mergerfs` (`homelab.mounts.fuse`):
- virtiofs `/mnt/virtio` = prom ZFS `nvmeprom/containers` (mountpoint
  `/nvmeprom/containers`), with child datasets `Music` + `media_metadata`.
- NFS `/mnt/data` = tower `192.168.1.2:/mnt/user/data` (hard mount).
- NFS `/mnt/appdata` = tower `192.168.1.2:/mnt/user/appdata`.
- mergerfs unions, e.g. `/mnt/fuse/Media/Movies` = `virtio/media_metadata/Movies`
  (metadata) **:** `data/Media/Movies` (NFS media files), and similar for TV/Music.

**LXC cannot use virtiofs, and an unprivileged CT cannot mount NFS itself.** So:

| Today (VM) | After (CT) |
|---|---|
| virtiofs `/mnt/virtio` ← `containers` | Proxmox `mp0` **rbind** of `/nvmeprom/containers` → `/mnt/virtio` (rbind carries the `Music`/`media_metadata` child datasets) |
| NFS mounted *in the VM* (`/mnt/data`, `/mnt/appdata`) | NFS mounted **on prom**, then Proxmox `mp1`/`mp2` **bind** into the CT |
| `mergerfs` in the VM unions virtio+NFS | `mergerfs` stays **in the CT** (`homelab.mounts.fuse`, fuse works in LXC) over the bind-mounted sources |

→ `homelab.mounts.nfsLocal` is **dropped** from the CT (NFS moves host-side);
`homelab.mounts.fuse` (mergerfs) **stays**. Watch the unprivileged idmap UID-shift
on any *shared* trees (the mailsearch cross-host UID note applies).

---

## Pre-reboot prep (staged — does NOT touch the live VM or fleet eval)

1. **Runbook** — this file.
2. **CT NixOS config** — `hosts/igpu/configuration-lxc.nix` (a complete alternative
   config; **unwired** from `hosts.nix` so it cannot affect fleet eval until cutover).
   At cutover, flip the `igpu` host entry's `configurationFile` to this file.
3. **CT template** — build with
   `nix run github:nix-community/nixos-generators -- -f proxmox-lxc --flake .#igpu`
   (after wiring), upload to a `vztmpl` storage on prom.
4. **prom CT config** staged (`/etc/pve/lxc/<id>.conf`), see below.
5. **prom kludge retirement** staged: remove the `vendor-reset` udev rule for
   `0x13c0` + the `/etc/modules` `vendor-reset` line so the reboot brings up
   `amdgpu` cleanly. (prom has **no** vfio binding or amdgpu blacklist to remove —
   Proxmox binds vfio-pci dynamically at VM-start only; with `hostpci0` already
   removed from the VM, nothing claims the GPU, so `amdgpu` binds it at boot.)

### Recon (prom, 2026-06-29 — concrete cutover values)

- **CT id:** `107` (`pvesh get /cluster/nextid`).
- **Template storage (vztmpl):** `local` (dir, ~200 GB free) — upload the tarball here.
- **CT rootfs:** on **`nvmeprom`** (zfspool) — owner directive (keeps the CT's real
  state in the ZFS backup/snapshot regime).
- **Podman overlay store:** a **dedicated ext4 disk mounted at `/var/lib/containers`**
  (owner's call) → podman gets native `overlay2`, no fuse-overlayfs, no ZFS-overlay
  edge cases. Default it to `Test` (lvmthin → ext4, Proxmox-managed, zero manual
  steps): `mp3: Test:16,mp=/var/lib/containers`. It holds only regenerable container
  layers (images auto-update/re-pull), so it deliberately does **not** need ZFS
  backup. (If everything must live on `nvmeprom`: `zfs create -V 16G
  nvmeprom/ct-107-overlay && mkfs.ext4 /dev/zvol/nvmeprom/ct-107-overlay`, then mount
  it at `/var/lib/containers` — manual, since a zfspool `mpN` makes a ZFS subvol, not
  ext4.)
- **`fuse=1` is required regardless** — mergerfs (`homelab.mounts.fuse`) runs *inside*
  the CT and needs `/dev/fuse`.
- **Tower NFS reachable from prom:** confirmed. Exports: `/mnt/user/data`
  (LAN-scoped `192.168.1.0/24` — prom qualifies) and `/mnt/user/appdata` (`*`).

### Staged Proxmox CT config (`/etc/pve/lxc/107.conf`)

```
arch: amd64
ostype: unmanaged
unprivileged: 1
features: nesting=1,keyctl=1,mknod=1,fuse=1
cores: 8
memory: 16384
hostname: igpu
onboot: 1
net0: name=eth0,bridge=vmbr0,ip=192.168.1.33/24,gw=192.168.1.1
dev0: /dev/dri/renderD129,gid=303,mode=0666    # iGPU node (see gotchas: renderD129 + 0666)
dev1: /dev/net/tun                             # tailscale
mp0: /nvmeprom/containers,mp=/mnt/virtio,rbind=1
mp1: /mnt/tower-data,mp=/mnt/data,bind=1        # prom-mounted tower NFS
mp2: /mnt/tower-appdata,mp=/mnt/appdata,bind=1  # prom-mounted tower NFS
mp3: Test:16,mp=/var/lib/containers             # dedicated ext4 → native overlay2 (regenerable)
rootfs: nvmeprom:20                              # ZFS (owner directive) — real CT state, backed up
```

### prom-side NFS (staged on prom, additive/safe)

```
# tower exports (mounted on prom, then bind-mounted into the CT)
192.168.1.2:/mnt/user/data     /mnt/tower-data     nfs4  vers=4.2,hard,_netdev,noatime  0 0
192.168.1.2:/mnt/user/appdata  /mnt/tower-appdata  nfs4  vers=4.2,hard,_netdev,noatime  0 0
```

---

## Cutover (the reboot window)

**Build the template first** (anytime before the window — flipping `configurationFile`
to the LXC file *is* the wire-in; do it on a throwaway branch or accept the live VM
config is being retired anyway):
```
# wire: hosts.nix igpu.configurationFile = ./hosts/igpu/configuration-lxc.nix
nix run github:nix-community/nixos-generators -- -f proxmox-lxc --flake .#igpu -o /tmp/igpu-lxc
scp /tmp/igpu-lxc/*.tar.* root@prom:/var/lib/vz/template/cache/   # 'local' vztmpl
```
This is also the config's first **full eval/build** (it's only syntax+option-validated
while staged) — fix any eval error here, before the window.

Then, the window:
1. **Quiesce VM 109:** stop its services, `qm shutdown 109`. (Do NOT `qm stop` an
   iGPU VM — but it has no GPU now, so shutdown is clean. Keep it until verify, for
   rollback.)
2. **prom prep** (the staged commands):
   - Retire the kludge: remove the `0x13c0` line from `/etc/udev/rules.d/99-vendor-reset.rules`
     and the `vendor-reset` line from `/etc/modules` (no vfio binding/blacklist exists
     to remove — Proxmox only bound vfio at VM-start, and 109 no longer has `hostpci0`).
   - Add the tower NFS to prom `/etc/fstab` (the two lines above).
3. **Reboot `prom`** ← whole-fleet bounce. On boot, `amdgpu` claims `1002:13C0` →
   verify `ls -l /dev/dri/renderD128` on prom = `crw-rw---- root render` (PSP no longer
   wedged — the reboot cleared it).
4. **Mount the NFS:** `mount -a` on prom (the two tower mounts → `/mnt/tower-{data,appdata}`).
5. **Create the CT:** `pct create 107 local:vztmpl/<file>.tar.xz --ostype unmanaged --unprivileged 1`,
   write the staged `/etc/pve/lxc/107.conf` (dev0/dev1/mp0-3/rootfs), `pct start 107`.
6. **Identity + sops (fresh host key):**
   - Grab the CT's new host key: `pct exec 107 -- cat /etc/ssh/ssh_host_ed25519_key.pub`
     → update `igpu.publicKey` in `hosts.nix`.
   - Convert to age (`ssh-to-age`), set it as the `^hosts/igpu/` recipient in
     `.sops.yaml`, then `cd secrets && sops updatekeys hosts/igpu/*` (editor key on doc1).
   - Commit/push (signed).
7. **Deploy NixOS:** `fleet-deploy igpu` (or `nixos-rebuild` inside the CT) — it's a
   normal fleet host now (same fleet-update / signed-deploy path).
8. **Verify** (below).
9. **Decommission:** `qm destroy 109`; retire `ansible/prom_prox/patch_igpu_reset_PVE9.yml`
   (move to `old/`); update [`igpu-passthrough.md`](./igpu-passthrough.md) to point here.

---

## Verification (post-cutover)

- `pct exec <id> -- ls -l /dev/dri/renderD128` → `crw-rw---- root render`, render = gid 303 inside.
- `vainfo --display drm --device /dev/dri/renderD128` → `radeonsi`, lists HEVC enc.
- `vulkaninfo | grep -i radv` → `AMD RADV …` (proves whisper/mailsearch path).
- `journalctl -u podman-tdarr-node | grep -i encoder` → hardware encoder enabled.
- jellyfin: play a transcode, confirm VAAPI (not SW) in the ffmpeg log.
- whisper-server + mailsearch.embed: one inference each; `radeontop` shows GPU use;
  mailsearch stays `parallel=1` (2-CU `context lost` ceiling — a GPU limit, not LXC).
- mergerfs unions present: `/mnt/fuse/Media/{Movies,TV_Shows,Music}` readable+writable.
- **The whole point:** `pct reboot <id>` must NOT wedge the iGPU (no host reboot needed).
- `systemctl restart podman-tdarr-node` survives (exercises the `mknod=1` autoupdate path).

---

## Rollback

Until the VM is destroyed, rollback is: stop the CT, re-add `hostpci0: 0000:7a:00.0,pcie=1`
to VM 109, re-instate vendor-reset, reboot prom, start VM 109. (The PSP wedge that
started this is cleared by that same reboot.) Once the VM is destroyed and
`amdgpu` owns the host GPU, reverting means re-establishing vfio binding + a reboot.

---

## Open risks / gotchas

- **podman storage:** resolved by the dedicated **ext4** `/var/lib/containers` disk
  (`mp3`) → native `overlay2`, no ZFS-overlay risk. `mknod=1` is still required or
  container stop/start (and the nightly autoupdate restart) fails.
- **Security:** unprivileged CT is weaker isolation than the VM (shared kernel).
  Deliberate, accepted trade for eliminating the reset bug. Keep caps minimal.
- **idmap UID-shift** on shared bind-mounts — audit which `/mnt/virtio/<svc>` trees
  are written by more than one host before cutover.
- **render gid:** pin NixOS `users.groups.render.gid = 303` to match `dev0 gid=303`.
  (#1 silent-failure cause.) prom's host render gid is 993 — irrelevant, Proxmox
  idmaps `dev0`'s gid to the in-CT value.
- **Interface rename** `ens18`→`eth0` (mdnsReflector, mailsearch bind).

---

## Cutover gotchas — RESOLVED (2026-06-29, live)

Status: **DONE.** CT 107 live, all services active, `is-system-running = running`,
survives `pct reboot` with the GPU intact (reset bug gone). Diagram above still says
`renderD128` in places — the truth is **`renderD129`**; see #1.

1. **The iGPU is `renderD129`, not `renderD128`.** prom has TWO GPUs: the GTX 1080
   (nouveau, takes `renderD128`) and the iGPU (amdgpu `7a:00.0`, enumerates second →
   `renderD129`). Critically, do **NOT** rename it to `renderD128` inside the tdarr
   container: mesa/libva resolve the GPU via `/sys/class/drm/<name>`, and there
   `renderD128` is the *nvidia* card → VAAPI fails "Cannot open a VA display". Pass it
   through unchanged. `dev0: /dev/dri/renderD129,…`; jellyfin
   `hardwareAcceleration.device = "/dev/dri/renderD129"`; tdarr module gained a
   `renderDevice` option set to `/dev/dri/renderD129`. (A cleaner long-term fix would be
   to blacklist nouveau on prom so the iGPU becomes `renderD128` — deferred.)
2. **`dev0` mode `0666`, not `0660`.** tdarr's container process runs as uid 2010 (PUID),
   not in the render group, so a `0660 root:render` node denies it (jellyfin/whisper are
   native + in the render group, so they're fine at 0660). The VM's node was `0666`;
   match it. (Could instead `--group-add 303` the container if the image preserves it.)
3. **Fresh host key ⇒ re-key sops AND `flake.nix`.** The CT gets a new SSH host key, so
   `secrets/hosts/igpu/*` + every shared secret igpu is a recipient of must be
   `sops updatekeys`'d, the `igpu` recipient updated in `.sops.yaml`, AND the **hardcoded
   `igpu=age1…` in `flake.nix`'s `sopsRecipientScopeCheck`** must be updated or the push
   audit fails.
4. **Mount only igpu's own subdirs of the shared `containers` dataset**, and `chown` them
   to the CT's idmapped UIDs (`<ct-uid>+100000`): jellyfin `data/config/log`, whisper.
   The CT's NixOS UIDs differ from the VM's, so pin them (`users.users.jellyfin.uid=997`
   etc.) so the chown stays valid. Don't chown the shared `Music`/`media_metadata`.
5. **`chown -R /home/abl030`** in the CT — a root activation left `~/.config` & `~/.local`
   root-owned, breaking `home-manager-abl030`.
6. **The Cloudflare ACME cert** (jelly.ablz.au) only provisions once the CT can decrypt
   `acme-cloudflare.env` (i.e. after the sops re-key) — before that nginx serves a minica
   fallback. After re-key it self-heals to a real Let's Encrypt cert.
7. **Deploy bootstrap:** a fresh locked CT can't fetch Forgejo (its baked `nix-netrc` is
   encrypted to the old key). Build the toplevel **on doc1** and activate it in the CT via
   the LAN cache (`nix-store --realise` + `nix-env --set` + `switch-to-configuration`),
   `pct exec`'d as root with **full paths** (pct exec has a minimal PATH).

## Post-migration: gid-100 idmap for shared-tree writes (2026-07-04)

**Status: live.** The unprivileged idmap left the shared trees (`media_metadata`,
`Music`, the tower NFS binds) `nobody:nogroup` inside the CT — fine for reads,
fatal for *writes*. First casualty: jellyfin trickplay "save with media" failed
`UnauthorizedAccessException` on every item, so the daily task re-churned the
missing-trickplay backlog forever = the "14% CPU floor" incident (one pegged
core since 2026-06-27; predates the LXC — on the VM the same writes failed
because jellyfin lacked gid 100). Fix was five-layered; ALL are needed:

1. **CT 107 idmaps gid 100 (`users`) through** (`/etc/pve/lxc/107.conf` +
   `root:100:1` in `/etc/subgid` on prom; backup at `/root/107.conf.bak-trickplay`):
   ```
   lxc.idmap: u 0 100000 65536
   lxc.idmap: g 0 100000 100
   lxc.idmap: g 100 100 1
   lxc.idmap: g 101 100101 65435
   ```
   Deliberately gid-only: mapping uid 1000 too would let CT-root impersonate
   abl030 on every shared mount (incl. tower masters over the NFS bind).
2. **`media_metadata` normalized from doc2** (real UIDs there): `chgrp -R 100`,
   `chmod -R g+w`, dirs `g+s`. Branch **roots** `Movies`/`TV Shows` are `3777`
   (o+w + sticky): mergerfs's clone-path (creating a missing title dir on the RW
   branch) runs with credentials that can't use the group grant on
   unmapped-owner parents — o+w on just those two dirs is what lets clones
   happen. Cloned title dirs inherit the *source* (tower) dir's mode, hence:
3. **tower media dirs swept `g+w`** (69 stragglers were 755) and **radarr+sonarr
   now enforce `chmodFolder=775`** (Media Management → Permissions) so future
   imports stay group-writable.
4. **jellyfin's PRIMARY group is `users`** (`services.jellyfin.group`, commit
   f5efb901): mergerfs only honors the FUSE context uid + primary gid for the
   underlying op — **supplementary groups are dropped in the unprivileged CT**
   (verified: mkdir through the union succeeds with gid 100 primary, fails with
   gid 100 supplementary-only). `SupplementaryGroups=` is NOT enough for
   anything writing through `/mnt/fuse`.
5. **Remap fallout (bit us, will bite again on any idmap change):** files
   created pre-remap with CT gid 100 sat on disk as host gid 100100 — now
   unmapped, and **CT-root loses CAP_DAC_OVERRIDE over any inode whose uid OR
   gid is unmapped**. Consequences: activation `setupSecrets` failed
   (`mkdir /home/abl030/.local: permission denied`) and podman's layer store
   went unloadable (`error removing stale temp dir … permission denied`).
   Fixes: on prom `find <rootfs+service trees> -gid 100100 -exec chgrp -h 100`
   (353 files), and the podman store (`Test:vm-107-disk-0` LV, mount it on prom
   while the CT is stopped) was **wiped** — disposable, images re-pull. The
   re-pull burst tripped docker.io's anonymous rate limit (shared house IP);
   ghcr images were fine, `tailscale/tailscale` sat in retry until the window
   cleared.

**Known residual quirk:** *deletes* (`rm`/`rmdir`) through the mergerfs union
are denied even for callers whose creds pass the same check that lets *creates*
succeed — deletes work fine directly on the branch path. Unexplained mergerfs
behavior (2.42.0, unprivileged CT); harmless for trickplay (regeneration for
upgraded files writes a new dir name), but means jellyfin cannot delete media
via the union. Revisit if a service needs union deletes.
