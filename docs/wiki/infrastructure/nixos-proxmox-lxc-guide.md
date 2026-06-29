# Deploying a NixOS service as an unprivileged Proxmox LXC

**Status:** Working / battle-tested (first conversion: `igpu`, 2026-06-29).
**Reference implementation:** [`igpu-lxc-migration.md`](./igpu-lxc-migration.md) +
`hosts/igpu/configuration-lxc.nix`.

This is the repeatable recipe for moving a NixOS VM (or standing up a new service)
as an **unprivileged Proxmox LXC** on `prom`, managed by this flake exactly like any
other fleet host. Written after the igpu VFIO→LXC migration; every step here is one
we actually hit.

---

## Why (and when) LXC instead of a VM

| | VM | Unprivileged LXC |
|---|---|---|
| RAM | **fixed reservation** (igpu VM = 16 GiB pinned) | **only what's used** (igpu CT idles at ~2 GiB) |
| Reboot | full guest boot; GPU passthrough = AMD reset-bug risk | instant; **host owns the GPU driver → no reset bug** |
| Kernel | own kernel | **shares prom's kernel** |
| Isolation | strong (separate kernel) | weaker — a container escape needs a kernel LPE, but the boundary is the shared kernel |

**Good LXC candidates:** service hosts (media, web apps, databases, exporters),
**iGPU/render transcode** (host binds `amdgpu`, CT bind-mounts `/dev/dri` — sidesteps
the VFIO reset bug entirely), anything that doesn't need its own kernel.

**Keep as a VM:** VFIO **device passthrough** that needs the device exclusively
(the **gaming GPUs** — full GPU passthrough to Windows), workloads needing a different
kernel/modules, or where the shared-kernel blast radius is unacceptable.

**Always unprivileged.** Privileged CT-root *is* host root on prom → one escape = the
whole fleet. We reject it. The only thing privileged buys is dodging the idmap
UID-shift (step 5), which is cheap to handle.

---

## The recipe

### 1. NixOS config (`hosts/<h>/configuration-lxc.nix`)

```nix
{ lib, pkgs, modulesPath, ... }: {
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];
  # Do NOT import hardware-configuration.nix (VM disk/boot/efi boilerplate).

  proxmoxLXC = { privileged = false; manageNetwork = true; manageHostName = true; };

  networking = {
    hostName = "<h>"; useDHCP = false;
    interfaces.eth0.ipv4.addresses = [{ address = "<ip>"; prefixLength = 24; }];
    defaultGateway = "192.168.1.1"; nameservers = ["192.168.1.1"];
    useHostResolvConf = lib.mkForce false;  # else conflicts with base.nix systemd-resolved
  };

  # Neutralise VM-isms inherited from base.nix / the old host config:
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  services.fstrim.enable = lib.mkForce false;          # no block device
  networking.wireless.enable = lib.mkForce false;       # no wifi (kills wpa_supplicant)
  system.autoUpgrade.enable = lib.mkForce false;        # deploy via fleet-deploy; CT can't arm the realtime timer
  hardware.enableRedistributableFirmware = lib.mkForce false;  # host owns firmware
  # DROP from the old config: boot.kernelPackages/kernelParams, hardware.cpu.*.updateMicrocode,
  # services.qemuGuest, fileSystems (virtiofs/NFS) — see steps 5–6.

  # ...your homelab.services.* exactly as before...
  system.stateVersion = "25.05";
}
```

`base.nix` is LXC-friendly (its boot settings are `mkDefault`). Non-namespaced sysctls
(`kptr_restrict`, `dmesg_restrict`, `fs.inotify.*`) emit benign "read-only fs" warnings
in a CT — harmless; move `inotify` limits to prom if you need them.

### 2. hosts.nix entry

Standard entry; `configurationFile = ./hosts/<h>/configuration-lxc.nix`. Reuse the
hostname/IP. The host key will be **fresh** (step 7).

### 3. Build the template (on doc1)

`proxmox-lxc.nix` provides `system.build.tarball` directly:
```
nix build --no-link --print-out-paths .#nixosConfigurations.<h>.config.system.build.tarball
scp <result>/tarball/*.tar.xz root@prom:/var/lib/vz/template/cache/    # 'local' vztmpl
```

### 4. Create the CT

```
pct create <id> local:vztmpl/<file>.tar.xz \
  --ostype unmanaged --unprivileged 1 \
  --features nesting=1,keyctl=1,mknod=1,fuse=1 \
  --hostname <h> --cores N --memory M \
  --rootfs nvmeprom:20 \
  --net0 name=eth0,bridge=vmbr0,ip=<ip>/24,gw=192.168.1.1 \
  --onboot 1
```
- `nesting+keyctl+mknod` = rootful podman/OCI inside the CT; `fuse` = mergerfs/fuse-overlayfs.
- **podman overlay store on ZFS is flaky** → give `/var/lib/containers` a dedicated
  **ext4** disk: `--mp9 Test:16,mp=/var/lib/containers` (lvmthin = ext4; regenerable, no backup).

### 5. Storage (the meaty part)

- **virtiofs is VM-only.** Replace with Proxmox bind-mounts of host paths:
  `pct set <id> -mp0 /nvmeprom/containers/<svc>,mp=/mnt/virtio/<svc>` (NO `bind=1`/`rbind=1` —
  not valid `mp` keys). Mount **only the subdirs the service needs**, not a whole shared
  dataset (least-privilege + avoids cross-host exposure). Each ZFS child dataset is a
  single mount → plain bind; a recursive bind needs raw `lxc.mount.entry … rbind`.
- **Unprivileged idmap UID-shift:** CT uid X → host uid X+100000. So **chown the
  service's existing data** to the idmapped owner: `chown -R <ct_uid+100000>:<ct_gid+100000>
  /nvmeprom/containers/<svc>`. The CT's NixOS UIDs differ from the VM's — get them with
  `pct exec <id> -- getent passwd <svc>`, then **pin them** (`users.users.<svc>.uid = …`)
  so the chown stays valid across rebuilds. **Don't chown shared trees** other hosts write.
- **NFS:** an unprivileged CT can't mount NFS. Mount it on **prom** (`/etc/fstab`) and
  **bind** into the CT (`-mp1 /mnt/tower-data,mp=/mnt/data`).
- **`chown -R /home/<user>`** in the CT if a root activation left `~/.config`/`~/.local`
  root-owned (breaks home-manager).

### 6. GPU (render/transcode)

```
pct set <id> -dev0 /dev/dri/renderD12X,gid=303,mode=0666
```
- **Use the node's REAL name** (don't rename it in the container). mesa/libva resolve
  the GPU via `/sys/class/drm/<name>` — on a multi-GPU host, `renderD128` may be a
  *different* card's sysfs, so a rename → VAAPI "Cannot open a VA display". (On prom the
  iGPU is **`renderD129`** because the GTX 1080's nouveau takes `renderD128`.)
- `gid=303` = NixOS's static `render` gid; pin `users.groups.render.gid = 303`.
- **`mode=0666`** if a *containerized* consumer runs as a non-root PUID not in the render
  group (e.g. tdarr's uid 2010). Native services (in the render group) are fine at `0660`.
- `dev1: /dev/net/tun` for tailscale. radv (Vulkan) + radeonsi (VAAPI) both ride the
  render node — **no `/dev/kfd`**, no privileged CT.

### 7. Identity + sops (fresh host key)

The CT gets a new SSH host key → re-key everything it decrypts:
```
HK=$(pct exec <id> -- cat /etc/ssh/ssh_host_ed25519_key.pub)   # → hosts.nix publicKey
NEW=$(echo "$HK" | ssh-to-age)
# replace the host's OLD age key with $NEW in secrets/.sops.yaml (all rules), then:
cd secrets && for f in $(grep -rl <OLD_age> .); do sops updatekeys -y "${f#./}"; done
```
**Also update the hardcoded `<h>=age1…` in `flake.nix`'s `sopsRecipientScopeCheck`** or
the push audit fails. (ACME/Let's Encrypt certs only provision *after* this re-key — until
then nginx serves a minica fallback, which self-heals.)

### 8. Deploy (bootstrap)

A fresh **locked** CT can't fetch Forgejo (its baked `nix-netrc` is encrypted to the old
key). So build on doc1 and push the closure in via the LAN cache — `pct exec`'d as root
with **full paths** (pct exec has a minimal PATH):
```
TOP=$(nix build --no-link --print-out-paths .#nixosConfigurations.<h>.config.system.build.toplevel)
pct exec <id> -- /run/current-system/sw/bin/nix-store --realise $TOP
pct exec <id> -- /run/current-system/sw/bin/nix-env -p /nix/var/nix/profiles/system --set $TOP
pct exec <id> -- $TOP/bin/switch-to-configuration switch   # or 'boot' before a pct reboot
```
After the first deploy, the CT is a normal fleet host — subsequent changes go via
`fleet-deploy <h>` once it's on the tailnet (`pct exec <id> -- tailscale up`, then approve/tag).

---

## Verification checklist
- `systemctl is-system-running` = `running`, `systemctl --failed` empty.
- GPU: `vainfo --display drm --device /dev/dri/renderD12X` → `radeonsi`; for containers,
  run the encode **as the service's PUID** (`podman exec -u <uid> … ffmpeg -c:v hevc_vaapi … -f null -` → rc 0).
- `vulkaninfo | grep -i radv` for compute (whisper/llama).
- **`pct reboot <id>` must NOT wedge the GPU** (the whole point).
- Cert: `openssl s_client -connect <fqdn>:443` → `issuer = Let's Encrypt` (not minica).
- Logs flowing: `{host="<h>"}` in Loki. **Metrics: confirm node-exporter + process-exporter
  are scraped into Grafana** (a known gap on the first conversion — see igpu doc).

## Decommission
Leave the old VM **stopped** (`onboot=0`) for rollback until verified, then `qm destroy`.
Retire any per-host VFIO/reset hacks (e.g. `ansible/prom_prox/patch_igpu_reset_*`).
