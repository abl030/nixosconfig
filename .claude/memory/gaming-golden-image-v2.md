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

**Per-clone now also does Windows-Update-fully → MAS `/HWID`** (CVE hygiene for
cracked binaries; a fresh SMBIOS uuid drops HWID). Full runbook + the rebuild recipe
+ gotchas (windows-mcp UIPI/session-1, VB-CABLE custom-painted-window coordinate
click, prom-quorum/Caddy2.0-witness footgun) are in the **`gaming-vm` skill** and
`docs/wiki/services/apollo-gaming-vm.md`.

**Legacy still on prom (pending user decision on cleanup):** v1 template `119`
`WindowsGamingTemplate` + its linked clone `120 apollo-007-first-light` (has the
007 First Light game). Can't destroy 119 until 120 is gone. See [[prom-quorum-qdevice]].