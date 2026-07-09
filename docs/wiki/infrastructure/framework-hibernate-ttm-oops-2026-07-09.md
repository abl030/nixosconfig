# Framework "failed hibernate resume" — amdgpu/TTM oops AFTER a successful restore (kernel 7.1.3)

- **Date:** 2026-07-09 (incident + RCA same day) · **Status:** **RCA complete, independently
  verified (~90% confidence).** Root cause: **kernel 7.1.3 amdgpu/TTM regression** on the
  hibernate(S4)-resume path — NOT the just-swapped wifi card, NOT the hibernate fixes. No config
  change needed; mitigation is "boot the previous 7.1.1 generation if it recurs" and watch for a
  fixed 7.1.x. Upstream reporting: see [§ Upstream](#upstream-reporting).
- **Host:** `framework` (Framework 13 AMD Ryzen 7040, Radeon 780M/Phoenix iGPU, NixOS
  nixos-26.11.20260705, kernel 7.1.3).
- **Surface symptom:** opened the lid after ~40 h in hibernate → frozen/black screen → hard
  power-cycle → fresh boot, session lost. Read as "hibernate resume failed", and — because the
  MT7922→AX210 wifi swap ([framework-mt7921e-streaming-lag](framework-mt7921e-streaming-lag.md))
  had landed two days earlier — suspicion naturally fell on the new card.
- **Real cause:** the resume **succeeded end-to-end**. One second after `hibernation exit`, the
  first GPU command submission (gnome-control-center) hit a **kernel NULL-pointer oops in
  `ttm_lru_bulk_move_del`** (amdgpu/TTM buffer-move LRU bookkeeping). The dying task held a TTM
  spinlock with IRQs disabled; gnome-shell then deadlocked on that orphaned lock (RCU stall) →
  frozen compositor → hard reset.

## Timeline (all from `journalctl` on framework, AWST)

| When | Event |
|---|---|
| Jul 07 16:35 | Old boot (7.1.1, MT7922) enters s2idle; **wifi card swapped while suspended**; battery disconnect kills RAM state → cold boot |
| Jul 07 16:44 | First boot with AX210 — and **first boot on kernel 7.1.3** (same boundary; fully confounded in time) |
| Jul 07 17:14 | Rebuild/reboot drops the stale `mt7921e.disable_aspm=1` param |
| Jul 07 evening | Two clean s2idle suspend/resume cycles on 7.1.3 + AX210 |
| Jul 07 23:57 | suspend-then-hibernate writes the image, powers off |
| Jul 09 16:30:24 | Resume: `Hibernation image restored successfully` → `hibernation exit`. amdgpu hw re-init OK (PSP/SMU/DMUB resumed, all rings registered). iwlwifi resumes; BT firmware loads (`Fseq status: Success`) |
| Jul 09 16:30:25 | **Oops**: gnome-control-center's first `amdgpu_cs_ioctl` → NULL deref in `ttm_lru_bulk_move_del`; task dies holding a TTM spinlock (`exited with irqs disabled`, `preempt_count 1`); kernel tainted `D` |
| Jul 09 16:30:46 | gnome-shell page-faults a GPU buffer → `ttm_bo_populate → _raw_spin_lock` spins forever on the orphaned lock → RCU self-detected stall on CPU 6. Screen frozen |
| Jul 09 16:30:54 | Journal ends mid-daemon-chatter, no shutdown sequence — hard power-off |
| Jul 09 16:31:15 | Cold boot. `PM: Image not found (code -22)` — **normal**: the image was already consumed by the successful restore at 16:30:24 |

## The oops

```
BUG: kernel NULL pointer dereference, address: 0000000000000010
Oops: 0000 [#1] SMP NOPTI
CPU: 4 PID: 4480 Comm: .gnome-control- Tainted: G U W O 7.1.3 #1-NixOS
RIP: ttm_lru_bulk_move_del+0xe4/0x130 [ttm]
Call Trace:
 ttm_resource_free → amdgpu_bo_move → ttm_bo_handle_move_mem → ttm_bo_validate
 → amdgpu_cs_bo_validate → amdgpu_vm_validate → amdgpu_cs_parser_bos
 → amdgpu_cs_ioctl → drm_ioctl → __x64_sys_ioctl
note: .gnome-control-[4480] exited with irqs disabled
note: .gnome-control-[4480] exited with preempt_count 1
```

Full trace: `journalctl -b <boot-of-Jul-07-17:14> -k` around Jul 09 16:30:25 (preserved in the
framework's persistent journal). The `[O]` taint is the out-of-tree `framework_laptop` module —
unrelated; `amdgpu`/`ttm` are stock in-tree.

## Why NOT the wifi/BT swap (the obvious suspect)

- **Zero wifi/BT frames in either crash stack** — the oops and the stall are 100% `amdgpu`+`ttm`.
- Both radios demonstrably resumed healthy: iwlwifi re-initialized, BT firmware download completed
  3 s *after* the oops had already happened.
- The scary-looking `iwlwifi WFPM_UMAC_PD_NOTIFICATION` register lines at resume are **normal
  bring-up chatter** on this kernel — the identical group prints 3× during the clean cold boot.
- The hibernation image was *created with the AX210 already installed* (swap was 2 days before the
  hibernate), so there was no hardware mismatch at restore time. The new card had also already
  survived two s2idle cycles.
- No IOMMU faults / AER / DMA errors that could let a rogue device corrupt GPU memory.

## Why NOT the hibernate fixes

`hibernate-fix.nix` + `sleep-then-hibernate.nix` (drop_caches pre-hibernate hook, `zswap.enabled=0`,
`resume=` device, NFS suspend prep, amdgpu display flags) all govern **image writing and loading**
— which worked perfectly (`Hibernation image restored successfully`). Note `amdgpu.gpu_recovery=1`
cannot catch this class of failure: it recovers GPU *ring hangs*, not CPU-side kernel oopses in
driver bookkeeping.

## Why the 7.1.3 kernel is the cause (high confidence, not certainty)

- Hibernate resume was rock-solid before: **~50 successful image restores over months** on
  7.0.x/7.1.1, including 6/6 on the boot that ended Jul 7. **This was the first-ever S4 resume on
  7.1.3** — and it oopsed. First oops of any kind in the journal history.
- **The crash is S4-specific**: the same boot did three clean s2idle resumes on the same kernel.
  Only the deep hibernate GPU re-init path triggers it — which is why days of normal suspend use
  on 7.1.3 showed nothing.
- **Hardware fault ruled out**: no MCE/EDAC memory errors, no PCIe errors, and a deterministic
  NULL-at-fixed-offset-0x10 at a fixed RIP is a software logic-bug signature, not random
  corruption.
- The TTM bulk-move LRU code is a known NULL-deref hotspot upstream (drm/amd tracker issues
  1992/2034 are prior instances of this class; the `ttm_resource_add/del` bulk-move paths were
  reworked recently in the "swapped objects off the manager's LRU" series).
- Honest caveat: the kernel bump and the card swap landed at the **same boot boundary**
  (Jul 07 16:35→16:44), so they are fully confounded *in time* — only the crash-stack contents and
  the s2idle-clean/S4-crash split disambiguate them. And it's a single sample in a race-prone
  path; it may not reproduce on every S4 resume.

## Misleading breadcrumbs (so the next reader doesn't chase them)

- `PM: Image not found (code -22)` on the next boot ≠ failed resume. The restore consumed the
  image and cleared the `HibernateLocation` efivar 50 min earlier; this is the normal
  post-successful-resume state after a crash-in-between.
- `last -x` showing the boot ending in "crash" only means "no clean shutdown record" — true for
  the hard reset, but also true for the benign battery-disconnect during the card swap.
- The `WFPM_*` iwlwifi lines at resume (see above) are routine.
- A `[drm] Dirty helper failed: ret=-12` warning at resume is **chronic** — it also fires on the
  many successful resumes of earlier boots. Not a trigger.

## Verification method (worth reusing)

The RCA was re-derived from scratch by an independent subagent given **only the raw evidence**
(journal excerpts, boot history, hardware state) with all hypotheses left open and live SSH access
to verify — no conclusion or hypothesis in the brief. It converged on the same root cause (~90%),
corrected one detail (the card swap was one boot earlier than the cmdline-param removal implied),
and added the S4-vs-s2idle discriminator and the hardware-fault rule-out. Same
evidence-only-verification pattern as
[dns-saturation-incident-2026-05-22](dns-saturation-incident-2026-05-22.md).

## If it recurs

1. Boot the previous generation from systemd-boot (7.1.1 — dozens of clean S4 resumes) to confirm
   the regression, or bump nixpkgs and check whether a 7.1.4+ contains TTM bulk-move fixes.
2. The full oops in the persistent journal is ready-made for an upstream report (see below).
3. Do NOT touch the wifi card or the hibernate modules over this.

## Side finding

There was one earlier *silent* hibernate failure: the Jun 28 00:55 image was never restored (fresh
boot at 07:20, likely overnight battery drain before the resume was attempted). Different failure
mode (image never loaded vs. crash after successful load), on 7.1.1. Noted so a future "hibernate
is flaky" impression has both data points.

## Upstream reporting

Researched 2026-07-09 (web sweep: freedesktop drm/amd tracker, kernel Bugzilla,
lore/amd-gfx/dri-devel, Framework forum, NixOS, Arch BBS, Reddit). **No exact public match on all
three axes** (RIP `ttm_lru_bulk_move_del` + hibernate trigger + Phoenix/780M) — this looks like a
**new, reportable 7.1.x stable regression**. Caveat: gitlab.freedesktop.org is behind an Anubis
anti-bot wall, so do a quick manual browser search of the tracker before filing.

**The mechanism story (why the two crash symbols cohere):** `ttm_bo_populate` — where gnome-shell
deadlocked — was *introduced by* the 2024 TTM rework "move swapped objects off the manager's LRU
list" ([dri-devel v5](https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg508209.html)),
and hibernate is exactly that rework's swap-out → repopulate lifecycle. Both symbols live in the
same code region; its own author called the bulk-move handling "pretty fragile". A ChangeLog-7.1
snippet describes a bug of precisely this shape ("when the resource is the first in the bulk_move
range, adding it again … corrupts the list … eventually led to a null pointer deref in
`ttm_lru_bulk_move_del()`") — found only as a search snippet, commit hash unverified. Linux 7.1
released 2026-06-14; `drm-fixes-2026-07-04` carried amdgpu fixes — a stable-backport regression
landing between 7.1.1 and 7.1.3 is fully consistent with the clean→crash window.

**Closest neighbor (not a duplicate):**
[drm/amd #4178](https://gitlab.freedesktop.org/drm/amd/-/issues/4178) /
[nixpkgs #413932](https://github.com/NixOS/nixpkgs/issues/413932) — Framework 13 AMD + hibernate,
but a *silent black screen* (system alive underneath) on the 6.6 line, bisected to a 6.6.92
backport. Same subsystem + machine class, different symptom. Cross-link it when filing.

**Where + how to file:**
[gitlab.freedesktop.org/drm/amd/-/issues](https://gitlab.freedesktop.org/drm/amd/-/issues)
(confirmed the current canonical amdgpu/TTM venue; needs a freedesktop GitLab account). Include:
- Title: *"NULL deref in `ttm_lru_bulk_move_del` on first S4 hibernate resume — Phoenix/gfx1103
  (Radeon 780M), Linux 7.1.3 regression"*.
- The **full dual-trace dmesg** — the oops AND the follow-on deadlock (gnome-shell in
  `ttm_bo_populate → _raw_spin_lock`, "exited with irqs disabled", RCU stall). The held-spinlock
  chain is diagnostically important; don't trim it.
- The regression window stated outright: **7.1.1 = dozens of clean S4 resumes; 7.1.3 = crash on
  the first-ever S4 resume** — and offer a `git bisect` between the tags (expect them to ask).
- The **s2idle-clean / S4-only** discriminator.
- Taint disclosure: `framework_laptop` out-of-tree module (`O` taint) — platform/EC driver, no GPU
  involvement; offer to reproduce with it unloaded.

**Downstream heads-up venue:** Framework's Linux lead curates
["Active upstream AMDGPU issues affecting Ryzen 7840U (iGPU 780M)"](https://community.frame.work/t/active-upstream-amdgpu-issues-affecting-ryzen-7840u-igpu-780m/41053)
— fastest route to someone who escalates. Adjacent (different-symptom) reports:
[Hibernate broken on 6.14.2](https://community.frame.work/t/hibernate-broken-on-6-14-2/67837),
[Arch BBS: Framework 13 AMD inconsistent hibernate hard-freeze](https://bbs.archlinux.org/viewtopic.php?id=293242),
[nixpkgs #287586 (amdgpu resume NULL deref, different trace)](https://github.com/NixOS/nixpkgs/issues/287586).
