---
name: gaming-golden-image-v2
description: Apollo gaming golden template v2 (VMID 118, WindowsGamingTemplate-v2) — built+validated 2026-06-26 with windows-mcp + VB-CABLE + MAS baked in
metadata:
  type: project
---

**DONE 2026-06-26.** The Apollo gaming golden image was rebuilt as **VMID `118`
`WindowsGamingTemplate-v2`** (full clone of v1/119 → de-linked, then `qm template`).
Supersedes the prior 2026-06-25 WIP plan (now resolved/deleted).

**Baked into v2** (all validated as `.111`: stream 9012 pkts/14.8 MB, Apollo
`Selected audio sink: CABLE Input` → `Opus initialized`, VPN exit NL, LAN isolated,
windows-mcp doc1 401/200, `LicenseStatus=1`):
- Win 11 Pro 24H2 **fully updated** (26100.8655, online COM scan = 0) + **activated**
  (MAS `/HWID`).
- **windows-mcp** SSE server (v0.8.2, system Python 3.13.5), autostarts session 1,
  `0.0.0.0:8765`, bearer `wKRrAi5MN9OmJsP81UYrXhy_9vftpYG3QBRnSeqt0NI` +
  `--ip-allowlist 192.168.1.29`. The `8765`-from-`.29` pinhole now lives in the
  **`apollo_vpn` group** (clones inherit it).
- **VB-CABLE**: `CABLE Input (VB-Audio Virtual Cable)` = abl030 default playback +
  Apollo `audio_sink`. (Audio crackle was really client-side rtprio —
  `hosts/common/realtime-audio.nix` — but VB-CABLE is the user's chosen, proven sink.)
- Inherited from v1: NIC offloads off, auto-login, Apollo + pairings, GPU passthrough,
  shared MAC `BC:24:11:5E:E5:00`→.111.

**Per-clone provisioning: Windows-Update-fully → MAS activate** (CVE hygiene for
cracked binaries). ⚠️ Use MAS **`/KMS38` (offline)** on clones, NOT `/HWID` — HWID
needs MS servers and they **reject the AirVPN NL egress** (e2e-test finding). HWID
only works with direct WAN (the template build itself). Full runbook + rebuild recipe
+ gotchas are in the **`gaming-vm` skill** and `docs/wiki/services/apollo-gaming-vm.md`.

**E2E skill test done 2026-06-26 (RDR2, VM `121 apollo-rdr2`):** first real clone —
RDR2 [FitGirl] installed (116.8 GB, CRC-verified), streams, tile added. The cold test
surfaced real skill gaps now folded in: no game-install guidance (LAN-isolated clone
can't reach the NAS share → scp-in over SSH:22 or temp 445 pinhole; FitGirl is
GUI-only, no `/VERYSILENT`; drive it via windows-mcp with `EnableLUA=0`+reboot →
High-IL), KMS38-behind-VPN, and the Moonlight per-host app-list cache (new-clone tiles
invisible to paired clients until the GUI refreshes). NOTE the test read the *stale*
main-checkout skill (doc1 was behind origin/master), so its "template=119 / windows-mcp
missing" findings were already v2-fixed.

**Prom gaming VMs now:** `118` v2 template; `120 apollo-007-first-light` (de-linked
onto nvmeprom 2026-06-26, kept for save files); `121 apollo-rdr2` (RDR2). **v1 template
`119` DESTROYED 2026-06-26.** See [[prom-quorum-qdevice]].