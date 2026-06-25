---
name: gaming-vm-mcp-audio-wip
description: WIP (2026-06-25) — Windows-MCP + VB-CABLE on the Apollo gaming VM; audio-crackle fix unconfirmed; resume points + template-rebuild plan
metadata:
  type: project
---

Day-long session on the Apollo gaming VM (`gaming-vm` skill). Resume state as of 2026-06-25 evening; **pick up tonight**.

**Stream-jank diagnosis (DONE, solid):** encode = GTX 1080 NVENC (~10% util, not software), decode = epi Arc A310 VAAPI (~0.4ms), LAN 0% loss. Video judder is NOT encode/decode — it's the **SudoVDA virtual display capped at 60Hz** (Apollo asks 144 → gets 60Hz). Decided: stay coherent 60fps everywhere (no per-client 144 override). 8-bit > 10-bit (set epi moonlight `hdr=false`).

**Audio crackle — root cause NOT confirmed.** Objective tone test (validated analyzer: pristine = 87.5dB purity/0% dropouts) showed the captured 440Hz tone is badly degraded: null-HDA = 18.9dB/27% dropouts; **VB-CABLE = 20.5dB/33% — basically unchanged, so VB-CABLE did NOT fix it.** Measurement is CONFOUNDED: (1) test sources unreliable (SoundPlayer won't route to the cable → silent; Edge throttles → false gaps), (2) recording is on epi whose **`rtprio` fix is committed but NOT deployed** (low-priority audio thread underruns would add the flat ~27-33% to every recording). **Decisive next test: deploy `rtprio` on epi/framework, then ear-test a REAL game** (clean WASAPI audio → cable → Apollo). Full detail in `docs/wiki/services/apollo-gaming-vm.md`.

**Committed/pushed:** `hosts/common/realtime-audio.nix` (rtprio/nice for @users, imported by epi+framework) — on master, **needs `sudo nixos-rebuild` on epi+framework** (owner-deployed).

**Windows-MCP (WORKS, on VM 120):** GUI-automation MCP. SSE endpoint `http://192.168.1.111:8765/sse`, bearer `wKRrAi5MN9OmJsP81UYrXhy_9vftpYG3QBRnSeqt0NI`. Python 3.13 + uv + `uv tool install windows-mcp`. Autostarts in **session 1** via Run-key `HKCU\...\Run\WindowsMCP` → `C:\Users\abl030\start-winmcp.cmd`. Reachable from doc1 (LAN pinhole: 120.fw `IN ACCEPT src 192.168.1.29 dport 8765` + Windows fw `WindowsMCP-In-doc1`; had to delete 2 auto-created python.exe inbound BLOCK rules). **KEY gotcha:** windows-mcp is medium-integrity so it CAN'T click `requireAdministrator` windows (UIPI) — fix = `ConsentPromptBehaviorAdmin=0` + have its PowerShell tool relaunch a `-Verb RunAs` helper to click. This is what enables game-installer automation.

**VB-CABLE (installed, VM 120):** v2.1.5.8, `CABLE Input/Output` present. Apollo `sunshine.conf`: `audio_sink = CABLE Input (VB-Audio Virtual Cable)`. CABLE Input set as default playback (AudioDeviceCmdlets, installed). Keep until the rtprio test decides if it's needed.

**Plan (user's, correct): bake once, not per-clone.** Once a working audio fix is CONFIRMED by ear: clone a fresh **game-less** VM from template 119 → run the recipe (windows-mcp + VB-CABLE + clean host) ONCE → `qm template` it → new golden template, retire 119. Update skill: new template, bake the 8765 pinhole into the `apollo_vpn` group, document windows-mcp usage + the `-Verb RunAs` click pattern. Avoids ~500k tokens/clone.

**Box state:** re-LOCKED — VM 120 WAN off (120.fw `policy_out: DROP`), AirVPN-only egress + kill-switch restored (temp pfSense normal-egress rule removed; Tailscale-return `.111→100.64/10` rule kept). **Cleanup still pending:** revert the experimental QEMU audio args on 120 (`args:` line — VB-CABLE makes the null-backend tuning moot; restore plain `audio0: device=ich9-intel-hda,driver=none`). VM 120 also carries debug cruft (Edge tone, `Tone`/`Mo` scheduled tasks, `C:\vbcable`, tone.wav) — cleared at template-rebuild.
