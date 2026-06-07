# virtiofsd FD Exhaustion on prom (`/mnt/virtio` ENFILE)

**Date researched:** 2026-06-07
**Status:** Fixed — live on doc2; doc1/igpu activate on their next reboot
**Hosts:** prom (hypervisor) + every guest that mounts `nvmeprom/containers` via virtiofs (doc2, doc1, igpu)
**Issue:** [#267](https://github.com/abl030/nixosconfig/issues/267)
**Related:** [#268](https://github.com/abl030/nixosconfig/issues/268) (ZFS+PBS service-state backup), [pfsense-backup.md](pfsense-backup.md) (other virtiofs-submount gotchas)

## TL;DR

A guest doing a large filesystem walk on a virtiofs mount can hit **`Too many open files in system` (ENFILE)** even though the *guest's* own fd limits are nowhere near full. The limit being hit is **host-side**: the Rust `virtiofsd` (default `--inode-file-handles=never`) keeps **one open `O_PATH` fd per inode the guest has looked up**, capped by its `RLIMIT_NOFILE` (default `1,000,000`). Proxmox only enables the fix flag (`--inode-file-handles=prefer`) for **Windows** guests, so Linux guests are exposed. Fix: a `dpkg-divert` wrapper on prom that adds `--inode-file-handles=prefer --modcaps=+dac_read_search`.

## Symptom

- On a guest: `ls`/`find`/`du`/any open on `/mnt/virtio` intermittently fails with `Too many open files in system` (ENFILE, errno 23), typically during heavy traversal (e.g. a backup walking 100k+ files, or a busy slskd download dir).
- The guest's own limits are fine and not the cause: `cat /proc/sys/fs/file-nr` shows few open files and `fs.file-max` is effectively unlimited. **If the guest looks innocent, the bottleneck is host-side virtiofsd.**

## Root cause

`virtiofsd` must be able to open arbitrary inodes the guest references. In the default mode it does this by **holding an `O_PATH` file descriptor in each `InodeData`** for as long as the guest keeps a reference (FUSE lookup count). So the host-side fd count tracks the **guest's cached-inode count**, not the number of files the guest has `open()`ed. A big tree walk inflates the guest inode cache → virtiofsd's fd count climbs to `RLIMIT_NOFILE` and starts returning ENFILE to the guest.

- `RLIMIT_NOFILE` default for virtiofsd = `min(1000000, /proc/sys/fs/nr_open)` → **exactly 1,000,000** here. Raising it is **not** the fix (and is CVE-2020-10717 territory: a guest could then exhaust the *host's* global fd budget).
- Proxmox (`/usr/share/perl5/PVE/QemuServer/Virtiofs.pm`) adds `--inode-file-handles=prefer` **only for Windows guests**: `my $prefer_inode_fh = PVE::QemuServer::Helpers::windows_version($conf->{ostype}) ? 1 : 0;`. Our Linux guests (`ostype: l26`) never get it.

Measured on 2026-06-07: doc2's `containers` virtiofsd held **981,526 / 1,000,000** fds; the guest had ~1.9M cached inodes. (igpu ~529k, doc1 ~118k — same mechanism, less acute.)

## How to diagnose

On **prom** (find the virtiofsd serving the guest + its fd usage):

```sh
# virtiofsd processes and their shared dirs
ps -eo pid,args | grep '[v]irtiofsd'
# per-process RLIMIT_NOFILE and current open fds
for p in $(pgrep -f virtiofsd); do
  echo "pid $p: $(ls /proc/$p/fd 2>/dev/null | wc -l) fds / limit $(awk '/open files/{print $4}' /proc/$p/limits)"
done
```

On the **guest** (confirm it's not the guest's limit, and that the cache is the driver):

```sh
cat /proc/sys/fs/file-nr      # open/unused/max — will be low + effectively unlimited
cat /proc/sys/fs/inode-nr     # nr_inodes — this is what virtiofsd's fd count tracks
```

**Proof experiment** (confirms the coupling, and is also the immediate relief): drop the guest's dentry/inode cache and watch the host virtiofsd fd count collapse:

```sh
# on the guest
sync && echo 2 > /proc/sys/vm/drop_caches
# on prom, re-check the same virtiofsd pid's fd count — it falls to ~1k
```

Observed: doc2 virtiofsd `981,526 → 1,446` fds; guest `inode-nr 1.9M → 37k`. Not a leak — faithful inode-cache tracking.

## The fix (durable, prom-side)

Make virtiofsd use **file handles** instead of holding an fd per inode. PVE has the flag but gates it to Windows, and editing `Virtiofs.pm` directly is **reverted on every `pve-manager`/`qemu-server` upgrade**. Use a `dpkg-divert` wrapper instead — it survives package upgrades:

```sh
# on prom
dpkg-divert --add --rename --divert /usr/libexec/virtiofsd.distrib /usr/libexec/virtiofsd
cat > /usr/libexec/virtiofsd <<'EOF'
#!/bin/sh
exec /usr/libexec/virtiofsd.distrib "$@" --inode-file-handles=prefer --modcaps=+dac_read_search
EOF
chmod 0755 /usr/libexec/virtiofsd
```

- `prefer` (not `mandatory`) is safe: it falls back to O_PATH fds if a filesystem can't produce handles.
- `--modcaps=+dac_read_search` is **required** — `open_by_handle_at` needs `CAP_DAC_READ_SEARCH`, which virtiofsd's namespace sandbox would otherwise drop. Without it, `prefer` silently falls back to fds and you get **no benefit**.
- Applies to **all** prom virtiofsd instances (doc1/doc2/igpu, plus the `Music`/`mirrors`/`media_metadata` shares) — all benefit.

### ⚠️ Activation gotcha: `qm reboot`, not a guest reboot

virtiofsd is forked by `qemu-server` when the **VM process starts**. A guest-internal reboot (`reboot` inside the guest / ACPI) does **not** re-fork virtiofsd — the VM stays "running" from Proxmox's view. You must do a full power-cycle: **`qm reboot <vmid>`** (Proxmox implements this as shutdown+start) or `qm stop`/`qm start`. Verify the new process carries the flags:

```sh
ps -eo pid,args | grep -- '--inode-file-handles'
```

## ZFS caveat — checked, OK here

`--inode-file-handles` only helps if the backing filesystem implements `name_to_handle_at`/`open_by_handle_at`. The host fs is ZFS (OpenZFS support has historically been called incomplete). **Tested on prom 2026-06-07** with a `ctypes` `name_to_handle_at`+`open_by_handle_at` probe — succeeds on both `nvmeprom/containers` and the child `nvmeprom/containers/Music` dataset (handle_bytes=12). So `prefer` genuinely engages here. If you move the share to a different fs, re-test; `prefer` will just no-op (fall back to fds) on a fs without handle support.

## Verification (post-fix)

Walked the full `/mnt/virtio` tree (585,561 files) with the fix active:

| metric | before fix | after fix |
|---|---|---|
| guest cached inodes | ~1.9 M | 1.21 M (rebuilt by the walk) |
| containers virtiofsd fds | **981,526** | **953** |
| `ls /mnt/virtio/music/slskd/` | ENFILE | OK |

~1000× fewer fds for a comparable inode cache. Coupling broken.

## When to revisit

- **doc1 / igpu** still run the old virtiofsd until their next reboot — they'll pick up the wrapper automatically (it's the shared prom binary).
- **PVE upgrades:** the diversion survives, but if a future PVE exposes a native knob for `--inode-file-handles` (Proxmox staff have said they "could add an option"), switch to that and remove the diversion. Also watch for PVE starting to add the flag itself for Linux guests → would be passed twice (last-wins or clap error); revisit the wrapper then.
- **virtiofsd default:** newer virtiofsd (`main`) reportedly defaults `--inode-file-handles=prefer`; our 1.13.2 defaults to `never`. A future virtiofsd bump may make the wrapper redundant — verify and retire it if so.
- **Defense-in-depth (optional):** cap slskd concurrency to bound active opens. Minor — active opens were ~600 vs ~1M cached-inode fds, so concurrency was never the driver.

## Sources

- virtiofsd v1.13.2 README — `--inode-file-handles`, `--rlimit-nofile` defaults: <https://gitlab.com/virtio-fs/virtiofsd/-/raw/v1.13.2/README.md>
- virtiofsd Config docs — O_PATH-fd-per-inode rationale + why the fd is held: <https://virtio-fs.gitlab.io/virtiofsd/doc/virtiofsd/passthrough/struct.Config.html>
- CVE-2020-10717 — why raising rlimit is unsafe: <https://lists.gnu.org/archive/html/qemu-devel/2020-05/msg00140.html>
- PVE patch gating `prefer` to Windows guests: <https://www.mail-archive.com/pve-devel@lists.proxmox.com/msg26387.html>
- Proxmox forum "virtiofs 1 million files limit": <https://forum.proxmox.com/threads/virtiofs-1-million-files-limit-on-windows-guests.165565/>
