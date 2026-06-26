---
name: gaming-golden-image-v3
description: Apollo gaming golden template v3 (VMID 117, WindowsGamingTemplate-v3) — DONE 2026-06-26; bakes game-install deps so installs need no WAN; UAC stays on; work-laptop paired
metadata:
  type: project
---

**DONE 2026-06-26.** Apollo gaming golden template **v3 = VMID `117`
`WindowsGamingTemplate-v3`** (full clone of v2/118 → de-linked → `qm template`).
Current template — clone THIS one. v2/118 is legacy (kept only while `121 apollo-rdr2`
links to it; retire 118 once 121 is de-linked). Supersedes [[gaming-golden-image-v2]].

**New in v3 (on top of all v2 features — windows-mcp, VB-CABLE, offloads-off,
auto-login, Apollo, shared MAC .111):**
- **Game-install prerequisites pre-baked** so a clone installs games **with WAN cut**:
  VC++ 2008/2010/2012/2013/2015-2022 (x64+x86), **DirectX June-2010 runtime**
  (d3dx9/11, xinput, xaudio — verified `d3dx9_43.dll`), **.NET 3.5 Enabled**.
- **UAC stays ON** (user's call — guard against a misbehaving cracked binary). Drive
  elevated installers via the **elevated session-1 task** (`/RU abl030 /IT /RL
  HIGHEST`), NOT EnableLUA=0.
- **The user's work laptop is now paired** (baked into Apollo, like framework/epi/etc).

**WAN-cut policy (strong, user-set):** a FitGirl repack is untrusted — cut the clone's
WAN **before** launching its installer and **never** re-open it. Order: Windows Update
+ activation (need WAN) → **cut WAN** → copy repack in over LAN (SSH:22) → install
offline. If a game needs internet to RUN, the agent does NOT enable WAN — it finishes
the whole skill, then surfaces the ask to the user at the very end; the user decides.

**Caveats:** (1) **Activation is cosmetic and was finicky** — KMS38 wouldn't apply via
headless `qm guest exec`/scheduled-task, so v3 shipped status-5/unactivated; games run
fine unactivated, don't block on it. (2) **Don't thrash the GPU reset** — clean
`qm shutdown` + let the 1080 settle before the next start; back-to-back shutdown→set→start
(MAC change) or SIGTERM of a guest hung mid-GPU-init **wedges** the card
(`failed to reset PCI device … got timeout`); recover via PCI remove/rescan + vfio
rebind, last resort a prom reboot. (3) The flaky **ata8** SATA disk (controller
`15:00.0`) is being **physically removed** by the user — the libata.force + systemd-unit
mitigations I'd added were **removed** at the user's request.

Full runbook: `gaming-vm` skill + `docs/wiki/services/apollo-gaming-vm.md`.
See [[prom-quorum-qdevice]] (prom needs the Caddy2.0 witness for `qm` writes).