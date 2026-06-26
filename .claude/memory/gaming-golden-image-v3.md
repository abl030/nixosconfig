---
name: gaming-golden-image-v3
description: Apollo gaming golden template v3 (VMID 117, WindowsGamingTemplate-v3) — DONE 2026-06-26; bakes game-install deps so installs need no WAN; UAC stays on; work-laptop paired
metadata:
  type: project
---

**DONE 2026-06-26.** Apollo gaming golden template **v3 = VMID `117`
`WindowsGamingTemplate-v3`** (full clone of v2/118 → de-linked → `qm template`).
Current template — clone THIS one. **v2/`118` and v1/`119` templates (and the RDR2
test clone `121 apollo-rdr2`) were all DELETED 2026-06-26 — `117` is the ONLY gaming
template now**; the only other gaming VM is `120 apollo-007-first-light`.

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

**Caveats:** (1) **Activation: KMS38 is DEAD; HWID-online is the only way.** MS removed
`gatherosstate.exe` (build 26040) + fully deprecated KMS38 at 26100.7019, so `/KMS38`
silently no-ops on 26100.8655 (that's why early attempts ran exit-0 but never licensed).
**HWID is online** → needs a Microsoft-accepted IP; the AirVPN NL exit is **rejected**, so
HWID must run on a **direct-WAN** MAC (a clone's fresh random MAC) BEFORE applying `.111`.
Run the AIO directly as SYSTEM (`MAS_AIO.cmd -el /HWID`) — the `irm|iex` loader's `-Verb
RunAs` detaches headless. **Proven 2026-06-26: VM 120 (007) HWID-activated** over the AU
residential IP (temporarily swapped off `.111` to a temp MAC, activated, swapped back +
re-locked). The v3 template itself shipped unactivated (cosmetic — games run fine). (2)
**Don't thrash the GPU reset** — clean
`qm shutdown` + let the 1080 settle before the next start; back-to-back shutdown→set→start
(MAC change) or SIGTERM of a guest hung mid-GPU-init **wedges** the card
(`failed to reset PCI device … got timeout`); recover via PCI remove/rescan + vfio
rebind, last resort a prom reboot. (3) The flaky **ata8** SATA disk (controller
`15:00.0`) is being **physically removed** by the user — the libata.force + systemd-unit
mitigations I'd added were **removed** at the user's request.

Full runbook: `gaming-vm` skill + `docs/wiki/services/apollo-gaming-vm.md`.
See [[prom-quorum-qdevice]] (prom needs the Caddy2.0 witness for `qm` writes).