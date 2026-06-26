---
name: gaming-v3-build-resume
description: RESUME POINT — Apollo gaming template v3 build (VM 117) paused mid-build by a wedged GPU; prom reboot pending to recover. Pick up here.
metadata:
  type: project
---

**Status 2026-06-26 (mid-build, PAUSED for a prom reboot).** Building Apollo gaming
**template v3 = VM `117` `WindowsGamingTemplate-v3`** (full clone of v2/118). Extends v2
with: per-game-install deps **baked into the template** so the FitGirl installer needs
**no WAN** — VC++ redists 2008/2010/2012/2013/2015-2022 (x64+x86), **DirectX June 2010
legacy runtime** (d3dx9/11, xinput, xaudio), **.NET 3.5 Enabled**. UAC stays **ON**
(user's call — the skill drives elevated installers via the `/RU abl030 /IT /RL HIGHEST`
elevated-session-1 task, NOT EnableLUA=0). 117's MAC is already set to the shared
`BC:24:11:5E:E5:00` (.111). Deps verified installed; build cruft (C:\deps*, BakeDeps*
tasks) cleaned.

**Why paused — wedged GPU.** Cycling the GTX 1080 passthrough too fast for the MAC
change (scripted shutdown→set→start back-to-back) hit the vfio **reset race** →
half-reset → Windows hung mid-GPU-init → had to SIGTERM it, which **wedged the card**
(`qm start` → `failed to reset PCI device … got timeout`). remove/rescan + nouveau-reset
both failed to clear it (nouveau bind itself hung in D-state). **GOTCHA for the skill:
after stopping a GPU VM, let the card settle before starting the next; NEVER SIGTERM a
guest hung mid-GPU-init.**

**Also fixed: flaky SATA disk on `ata8`** (dying, no /dev node, `scsi_eh_7` stuck in D —
suspected of stalling the kernel/GPU op). Blocked persistently via **`libata.force=8:disable`
appended to line 1 of `/etc/kernel/cmdline` + `proxmox-boot-tool refresh`** (verified in all
3 entries on ESP /dev/sda2). Backup: `/root/cmdline.bak` on prom (revert: `cp /root/cmdline.bak
/etc/kernel/cmdline && proxmox-boot-tool refresh`). Boot disk = sda (ata4, rpool) — untouched.
Note a stale ESP UUID `B99F-2C43` (gone) is skipped by refresh — harmless.

## RESUME after prom reboots (GPU healthy + ata8 gone):
1. `ssh root@192.168.1.12 'qm start 117'` → boots to `.111`. Verify: IP .111, Apollo
   Running, windows-mcp :8765, `d3dx9_43.dll` present, license. (Settle the GPU; don't cycle.)
2. **Ping the user to PAIR their WORK LAPTOP** against Apollo (apollo.ablz.au or
   https://192.168.1.111:47990, admin / `nx6mlZQUZdgvzNl4`, enter the PIN) — pairing bakes
   into the template (no sysprep). framework/epi/phone/shield already paired.
3. After they confirm paired: `qm shutdown 117` → `qm template 117`. v3 done.
4. **Then update the `gaming-vm` skill** to the new WAN-cut-before-installer flow (cut WAN
   permanently before launching the untrusted FitGirl installer; redists pre-baked so it
   installs offline), template VMID→117/v3, and the GPU-reset gotcha above. Retire v2/118
   once its linked clones (121 RDR2) are de-linked.

See [[gaming-golden-image-v2]] (v2 facts), [[prom-quorum-qdevice]].