# Apollo Headless Gaming VM — Complete Knowledge Dump (for the skill + context reset)

> Built 2026-06-24, VM 110. **STREAMING NOW WORKS.** This doc is the handoff after a multi-hour
> debug saga. Read the "THE FIX" and "CURRENT STATE / NEXT STEPS" sections first.
>
> **2026-06-24 evening update (post-streaming-fix tidy-up session):** NEXT STEPS 1–3 DONE +
> VERIFIED. All 3 firewalls RE-ENABLED (Windows / Proxmox `110.fw` `enable:1` / pfSense pos 29+30)
> and streaming re-verified (12.9 MB, 8.8k large pkts). Cruft CLEANED (Run key `ApolloDisplayFix`,
> 9 debug scheduled tasks, `C:\ProgramData\Apollo-tools`, custom "Game" app, `dd_configuration_option`,
> log→info). **Rebooted → offloads + auto-login + Apollo all PERSIST → streaming re-verified again
> (12.4 MB, 8.4k large pkts).** Item 4 (RAM 24→32) HELD pending an explicit go (blast radius = prom).
> Remaining before templating: pair epi / phone / nvidia-shield against the live VM (pairing persists
> into the template, no sysprep). Then steps 5–7 (de-link 107, template 110, clone test, skill).

---

## 🟢 v2 GOLDEN IMAGE — built & validated 2026-06-26 (VMID `118`)

The "rebuild a fresh template with windows-mcp + VB-CABLE baked" plan is **DONE**.
New golden template = **VMID `118` `WindowsGamingTemplate-v2`** (full clone of v1/119,
so de-linked). Built headless via `qm guest exec` (SYSTEM) + elevated session-1
scheduled tasks. Validated as `.111`: stream 9012 large pkts / 14.8 MB, Apollo
`Selected audio sink: CABLE Input` → `Opus initialized`, VPN exit NL, LAN isolated,
windows-mcp 401/200 from doc1, `LicenseStatus=1`. The full runbook lives in the
**`gaming-vm` skill → "Rebuilding the golden template"**; this section is the *why* +
the gotchas worth not re-discovering.

**What's new in v2 vs v1:** Windows 11 Pro 24H2 fully updated (26100.8655, online
COM scan = 0 pending) + **activated** (MAS `/HWID`, RETAIL digital license);
**windows-mcp** GUI-automation server (autostarts session 1, SSE `:8765`); **VB-CABLE**
as the audio sink. The `8765`-from-doc1 pinhole was moved into the **`apollo_vpn`
group** so all clones inherit it.

**The audio decision (settled).** The 2026-06-25 crackle was diagnosed as *client-side*
(Linux Moonlight rtprio ceilings → `hosts/common/realtime-audio.nix`), not the VM.
The objective tone test showed VB-CABLE did **not** beat the bare null-backend HDA
sink — both were bad only because rtprio wasn't deployed. After rtprio landed, the
user confirmed smooth audio by ear (framework, 2026-06-25). v2 nonetheless ships
**VB-CABLE** (user's call): `CABLE Input (VB-Audio Virtual Cable)` = default playback
+ Apollo `audio_sink`. It's a clean software-clocked sink (vs the null backend's
jittery 10 ms software timer) and is the proven-good config. The Intel-HDA `audio0`
stays as a fallback render endpoint.

**windows-mcp — install + the gotchas.** Server = `uv tool install windows-mcp`
(v0.8.2) on **system Python 3.13.5** (`C:\Program Files\Python313`), launched by
`C:\Users\abl030\start-winmcp.cmd` from abl030's **HKCU Run-key** so it lives in
**session 1** (it automates the *interactive* desktop — a session-0/SYSTEM launch
sees nothing). `serve --transport sse --host 0.0.0.0 --port 8765 --ip-allowlist
192.168.1.29 --auth-key <token>`. Controls: app-layer bearer + `--ip-allowlist`,
plus two Windows firewall allow rules (TCP 8765 from `.29`: `Program Any` +
`Program …python.exe`) — Windows auto-creates inbound **Block** rules for a new
listening python, which *override* allow rules, so delete them and pre-create the
allow rules before first listen. **UIPI:** the medium-IL server can't click
`requireAdministrator` windows; drive elevated installers from a `/RU abl030 /IT
/RL HIGHEST` scheduled task instead (elevated, session 1, no UAC prompt).

**VB-CABLE headless install — what works.** `VBCABLE_Driver_Pack45.zip`; add the
VB-Audio signer cert to `TrustedPublisher`+`Root` then `pnputil /add-driver
vbMmeCable64_win10.inf /install` → driver staged, **no trust prompt** — but the
**device is not created**; `VBCABLE_Setup_x64.exe` must run and its **"Install
Driver"** button be clicked. That window is **fully custom-painted**:
`EnumChildWindows` *and* UIAutomation return **zero** descendants, so neither
`BM_CLICK` nor UIA `Invoke` work. The only way is **screenshot → click by
coordinates** (button bottom-right, ≈ `(winX+755, winY+405)` in the 820×432 window;
the window's Y drifts run-to-run, so recompute from the live `BoundingRectangle`)
from an elevated session-1 process. Reboot finalizes; then `Set-AudioDevice`
(AudioDeviceCmdlets) makes CABLE Input the default playback.

**Operational footgun hit during the build: prom quorum.** prom is a **single node +
a corosync-QDevice witness running on the `Caddy2.0` KVM VM (`192.168.1.6`, on
tower)**. When `Caddy2.0` was down, prom dropped to 1/2 votes → pmxcfs **read-only** →
`qm clone` and firewall writes failed with `cluster not ready - no quorum?` (reads
still served from cache). Fix = start `Caddy2.0` (tower `virsh start`), not `pvecm
expected 1`. `corosync.conf`: `quorum.device.net.host: 192.168.1.6`.

## ⭐ THE FIX (the one thing that mattered — "it used to just work" piece)

**Disable the VirtIO NIC's UDP Segmentation Offload (USO) + LSO inside Windows.** This was the
ENTIRE cause of the "connects but blank/black, then disconnects" problem. Symptom: the VM emitted
only a single ~14 KB blank keyframe then nothing. With offloads disabled it emits **7+ MB of real
sustained video** (5000+ large packets/14s). The guest hands the virtio NIC an oversized UDP
super-packet for each large frame and it never makes it onto the wire — a well-documented
Sunshine-on-Proxmox bug. Older gaming VMs "just worked" because they likely used an **E1000** vNIC,
which doesn't have this bug.

Apply (persists across reboot; **bake into the template**):
```
qm guest exec 110 -- powershell.exe -NoProfile -Command "Get-NetAdapter | Disable-NetAdapterUso -IncludeHidden; Get-NetAdapter | Disable-NetAdapterLso -IncludeHidden; Get-NetAdapterAdvancedProperty | ? {$_.DisplayName -match 'Offload|USO|Large Send|LSO'} | % { Set-NetAdapterAdvancedProperty -Name $_.Name -DisplayName $_.DisplayName -DisplayValue 'Disabled' }"
```
Alternative/belt-and-suspenders fix (research said "solves immediately" on Proxmox): switch the vNIC
from `virtio` to **`e1000e`** keeping the same MAC: `qm set 110 -net0 e1000e=BC:24:11:5E:E5:00,bridge=vmbr0,firewall=1`.
(We did the offload-disable; consider e1000e for the template for robustness.)

**The OTHER required piece for headless: AUTO-LOGIN.** Without a logged-in user the VM sits at the
lock screen (`is_user_session_locked: true`) and there's no desktop to capture (black). Done via
registry Winlogon AutoAdminLogon (see "Config"). With auto-login + offloads-off, it streams the full
desktop at the client's native res (dynamic resolution works).

---

## 🔊 THE AUDIO FIX (2026-06-24 — discovered on first real clone, 007 First Light)

**Symptom:** video streams fine but the client has NO audio; Apollo log:
`Couldn't get default audio endpoint [0x80070490]` → `There will be no audio` →
`Unable to initialize audio capture`. (`Win32_SoundDevice` shows only the GTX
1080's `NVIDIA High Definition Audio` — its HDMI render endpoints are all
`NOTPRESENT` because nothing is plugged into the GPU's outputs on a headless VM,
so there is no active playback endpoint for Apollo to loopback-capture.)

**Fix — a VM-level emulated Intel-HDA sink** (no Windows software install needed,
uses the built-in HD Audio driver):
```
qm set <vmid> -audio0 device=ich9-intel-hda,driver=none
```
Then **stop+start** the VM (a guest reboot is NOT enough — QEMU only adds the
device on a fresh start). Windows then shows an ACTIVE "Speakers" endpoint and
Apollo logs: `Selected audio sink: {0.0.0.…}` → `Audio capture format is [F32
48000 2.0]` → `Opus initialized: 48 kHz, 2 channels, 96 kbps, LOWDELAY`.
`driver=none` is fine — QEMU's null audiodev keeps the render clock running so
loopback capture flows; nothing needs to play on the (headless) host.

**Baked into template 119**, so every clone inherits audio. (Alternative fixes
that also work but need a Windows install: Steam Streaming Speakers — Apollo
auto-detects it — or VB-CABLE. The VM-level HDA sink is cleaner: config-only.)

> ⚠️ **Caveat (2026-06-25):** `driver=none` keeps a render clock running, but it's
> QEMU's **software timer** (`timer-period` 10 ms default) — a *jittery* clock. WASAPI
> loopback is sensitive to clock steadiness, so under host load this is a plausible
> source of **audio stutter** (host-emit cadence measured mean ~3.5 ms but with
> mild jitter — gaps >10 ms present). If audio stutter persists after the client
> fix below, the more robust headless path is a real software-clocked sink
> (**Steam Streaming Speakers** via `virtual_sink`, or VB-CABLE), or tuning the null
> backend buffer via `args: -audiodev none,...,out.buffer-length=...`.

---

## 🎛️ STREAMING SMOOTHNESS / "JANK" TUNING — diagnosis 2026-06-25

Full objective diagnosis of "janky video + stuttery audio" (epi client, Arc A310
decode). **The pipeline has huge headroom — encode/decode/network were never the
bottleneck.** Measured on VM 120 streaming to epi (moonlight-qt 6.1.0, Wayland):

- **Encode = GTX 1080 NVENC, confirmed** (`Creating encoder [hevc_nvenc]`,
  `encoder.stats.sessionCount=1`). Only **7–14 % encoder util** even at 1440p — the
  1080 loafs. Not the jank. SDR streams are **8-bit HEVC**; 10-bit only when the
  client requests HDR (`dynamicRange:1`).
- **Decode = Arc A310 via VAAPI (iHD)**, ~**0.4 ms/frame**. Never the jank.
- **Network = pristine LAN**: 0 % loss, ~1 ms latency, 0 variance.
- **Root cause of video judder = the SudoVDA virtual display is capped at 60 Hz.**
  Apollo log: `Display mode requested [2560x1440x144]` → `Display refresh rate
  [60Hz]`. A browser's `requestAnimationFrame` locked to exactly 60 fps confirmed it.
  So a >60 fps request still delivers 60 fps, and a high-fps game sampled at 60 Hz
  judders. **It's an Apollo request-side default, not SudoVDA/the 1080.**
  - **Fix (only if you want true high-fps):** Apollo Web UI → PIN tab → set the
    client's **Display Mode Override** to `2560x1440x144` (format `WxHxR`; the
    override also becomes the encode fps in Apollo ≥4.0). See
    [Apollo wiki: Display-Mode-Override](https://github.com/ClassicOldSong/Apollo/wiki/Display-Mode-Override),
    issues [#935](https://github.com/ClassicOldSong/Apollo/issues/935) /
    [#1453](https://github.com/ClassicOldSong/Apollo/issues/1453).
  - **Decision (2026-06-25): NOT applied.** Keep the server universal across clients
    (epi/phone/laptop). Run a coherent **60 everywhere** (60 Hz vdisplay → 60 fps
    stream → epi's panel already at 60 Hz = clean 1:1 cadence, frame-pacing on). No
    per-client override that over-fits to epi.
- **8-bit > 10-bit:** the HDR/10-bit run measured *worse* (render 58.9 vs 60 fps,
  jitter-drop 1.38 % vs 0.55 %) for no gain on a game stream. Set the client to
  **8-bit / HDR off** (moonlight per-app `hdr=false`).
- **Audio stutter = client-side priority.** Host-emit audio cadence is steady;
  moonlight on epi logged `Unable to set audio thread to high priority:
  setpriority() failed` (user `rtprio`/`nice` ceilings were 0). Fixed declaratively
  for the Linux clients in **`hosts/common/realtime-audio.nix`** (imported by epi +
  framework). The host null-audio-backend jitter (caveat above) is a separate,
  universal contributor — revisit if stutter persists after deploying the client fix.

Reproducible test harness lived in the job scratch dir: Edge kiosk fullscreen
canvas (rAF motion, scales to the vdisplay refresh) + a Web Audio tone as the
load source; `moonlight stream … --fps/--resolution/--video-codec/--hdr`; metrics
from the moonlight perf summary, `tcpdump` on `tap120i0` (per-port packet cadence),
guest `nvidia-smi` (encoder util/session), and `intel_gpu_top`/`pw-top` on epi.

---

## 🟥 NON-ISSUES — DO NOT RE-CHASE THESE (we burned hours here for nothing)

- **The display / SudoVDA / "phantom" / primary**: NOT a problem. A screenshot taken in the
  interactive session showed the **full normal desktop** rendering on SudoVDA at 2256×1504, already
  PRIMARY. The `NVIDIA 1080 1024×768` that `Win32_VideoController`/`Screen.AllScreens` shows **over
  SSH is a Session-0 artifact** — in the real interactive session (auto-login) MMT sees ONLY SudoVDA,
  primary. The 24H2 "set-primary broken" rabbit hole was irrelevant once auto-login was on.
- **The resident "watcher" (Run key `ApolloDisplayFix` + `C:\ProgramData\Apollo-tools\watcher.ps1` +
  MultiMonitorTool)**: UNNECESSARY cruft from debugging. SAFE TO REMOVE (delete the HKLM\...\Run value
  `ApolloDisplayFix` and `C:\ProgramData\Apollo-tools`). It does nothing useful now.
- **The custom "Game" app in apps.json** (DisplaySwitch prep-cmd): unnecessary, can revert apps.json
  to default (Desktop / Steam Big Picture).
- **The firewall**: NOT the cause (tested with ALL firewalls off, still blank → it was offloads).
- **HAGS** (HwSchMode): we disabled it (HwSchMode=1) but it was NOT the cause; harmless to leave off.
- **dd_configuration_option / ensure_only_display / headless_mode primary stuff**: irrelevant to the
  fix. `dd_configuration_option = ensure_only_display` is currently set but didn't matter.
- Scheduled-task cruft to clean up: `DispExt, DispInt, DispEval, MmtList, S1b, S1Test` (and any
  `W2/WatcherSetup/AutoLogin/AutoLogin2` leftovers).

---

## 🔧 CURRENT STATE — ✅ ALL 3 FIREWALLS RE-ENABLED & VERIFIED (2026-06-24 eve)

**DONE — all firewalls back ON, streaming re-verified twice (incl. post-reboot):**
1. **Windows Firewall on VM = ON** (all 3 profiles True; persists across reboot). OpenSSH inbound
   rule survived, network SSH to .111 still works.
2. **Proxmox `/etc/pve/firewall/110.fw` = `enable: 1`** (compiles OK; `apollo_vpn` group intact in
   cluster.fw; datacenter fw `enable: 1`).
3. **pfSense pos 29 (pass .111→AirVPN_SG) + 30 (kill-switch) = ENABLED** (re-enabled via pfsense
   subagent, NO state flush). VM now exits via AirVPN (NL).

Verified working: 12.9 MB / 8.8k large pkts (first test) and 12.4 MB / 8.4k large pkts (post-reboot).
**Key fact: streaming from LAN clients works even with the VPN kill-switch on** — pfSense auto-excludes
LAN-destined traffic from the gateway policy route, so client↔.111 stays local; only .111's *internet*
egress rides AirVPN. The `apollo_vpn` group allows the streaming ports incl. the OUT UDP 47998:48010
return path.

---

## ✅ NEXT STEPS (the actual project, post-streaming-fix)

1. ✅ **DONE** Re-enable all 3 firewalls + re-verify streaming (above).
2. ✅ **DONE** Clean up cruft — removed Run key `ApolloDisplayFix`, `C:\ProgramData\Apollo-tools`,
   the custom "Game" app (apps.json now Desktop + Steam Big Picture only), and 9 debug scheduled
   tasks (DispEval/DispExt/DispInt/DisplayClear/DisplayEval/MmtList/S1b/S1Test/SessGather). Also
   `min_log_level=info` + dropped `dd_configuration_option`. **KEPT** `EnableSSH` task (redundant —
   sshd is Automatic+Running — but a harmless SSH-lifeline safety net).
3. ✅ **DONE & VERIFIED** Offloads-disabled survives reboot — post-reboot check: USO+LSO V2 (v4/v6)
   all Disabled, auto-login console=`Gaming-106\abl030` (session 1 Active, explorer up), Apollo
   auto-started, streaming re-verified.
4. ⏸️ **HELD (needs explicit go)** **Bump 110 RAM 24→32 GB** (`qm set 110 -memory 32768`). State as of
   tonight: doc1 (VM104) cfg already `memory:24576 / balloon:8000` and ballooned to ~16 GB (looks
   already-capped); prom = 123 GB total, ~24 GB available, running-VM cfg-max sum ~95 GB. With
   balloon:0 + passthrough the change is config-only until 110's NEXT boot, where it pins 32 GB — that
   boot is the OOM-risk moment (blast radius = prom = whole fleet). Left at 24 GB pending a go. Fleet
   RAM tuning = **Forgejo issue #12**.
4b. ▶️ **NEXT (user-interactive)** Pair the remaining Sunlight/Moonlight clients against the LIVE VM
   **before** templating (no sysprep = pair once, rides into every clone): **epi, phone, nvidia
   shield**. Path verified live: add `192.168.1.111` (or auto-discover `Gaming-106`) → enter PIN at
   `https://apollo.ablz.au` (admin / `nx6mlZQUZdgvzNl4`) → stream Desktop. (framework already paired.)
5. ✅ **DONE — with a KEY DEVIATION: the template is VMID `119` `WindowsGamingTemplate`, NOT 110.**
   Why: `qm move-disk 110 scsi0 Test` to de-link IN PLACE is REJECTED — *"you can't move to the same
   storage with same format"*. On **lvmthin you cannot de-link a linked clone within the same pool via
   move-disk**; the working de-link mechanism is a **full clone**. So: `qm clone 110 119 --full` (~90s
   on the T700) produced a de-linked golden copy (disks `origin=[]`), then `qm template 119`. Kept the
   original 110 (+ base 107) as rollback through validation, then **destroyed 110 + 107** (+ the orphan
   PBS backup) once the clone test passed. **STORAGE FACT:** `Test` lvmthin = `/dev/nvme0n1` = **Crucial
   T700, the single PCIe Gen5 NVMe** (32 GT/s ×4, PCI 02:00.0) — the correct drive. `nvmeprom` is the
   *separate* 3× Samsung 990 PRO Gen4 raidz1 (do NOT put the gaming VM there).
6. ✅ **DONE & VERIFIED — clone test = VMID `116`** (`apollo-gaming-test116`), linked clone of template
   119. **The recipe that works (this IS the skill's core):**
   `qm clone 119 <id>` → `qm set <id> -net0 virtio=BC:24:11:5E:E5:00,bridge=vmbr0,firewall=1` (shared
   MAC) → write `/etc/pve/firewall/<id>.fw` = just `[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out:
   ACCEPT\n[RULES]\nGROUP apollo_vpn` → `pve-firewall compile` → `qm start <id>`. Verified on 116:
   auto-login `Gaming-106\abl030`, got **.111** via shared-MAC DHCP reservation (**ZERO pfSense
   changes**), GPU+NVENC OK (`nvidia-smi` → GTX 1080 / 582.66), Apollo running, offloads off, stream
   11.96 MB / 8.1k large pkts, **VPN exit = NL** (213.152.187.243, Global Layer), **LAN isolation**
   confirmed (doc1/.29 + NAS/.2 both unreachable), DNS via gateway OK. 116 left RUNNING as the proof
   instance — tear down when building/testing the skill.
7. **Build the skill** `get me a new gaming windows vm`: ensure other gaming VMs off (single GPU) →
   linked-clone the template → set shared MAC → write `<vmid>.fw` → boot → Windows Update → verify
   GPU/Apollo/NVENC/stream/isolation/VPN-exit → hand over pairing. pfSense untouched (rides the MAC).
8. **Sysprep decision: NO sysprep** (one-at-a-time, isolated; identical SID/hostname harmless; keeps
   Apollo pairing constant = pair once, works on every clone).

---

## VM 110 — identity & access
- VMID **110**, name `Windows007`, Windows hostname **`Gaming-106`**, **Windows 11 24H2 (build 26100)**.
- SSH from **doc1**: `ssh -i ~/.ssh/win110_ed25519 abl030@192.168.1.111` (key-only; abl030 local admin).
- **Elevation**: SSH is non-elevated (UAC). For admin: SYSTEM via `qm guest exec 110 -- ...` (runs as
  SYSTEM) OR a `schtasks /RU SYSTEM /RL HIGHEST` task. Pattern: base64-push a .ps1, run as SYSTEM task,
  poll a `.status` file.
- **Run code in the INTERACTIVE desktop (Session 1)**: `schtasks /Create /TN X /TR "..." /SC ONCE
  /ST 23:59 /RU abl030 /IT /F` then `/Run` — **/IT WITHOUT /RP** (adding /RP breaks it!). Note: even
  this runs in a task-desktop, not always the real Explorer desktop — the **Run key** (HKLM\...\Run,
  fires at logon) is the only way to get the *real* interactive desktop. Display tools (MMT) need the
  real desktop.
- Windows password reset to **`ApolloGaming2026!`** (user doesn't care; admin via SYSTEM).
- Apollo web UI: `https://192.168.1.111:47990` and via Caddy `https://apollo.ablz.au` (admin /
  `nx6mlZQUZdgvzNl4`). API auth is **session/form login** (`/login`), NOT HTTP Basic.

## Config (what's installed/set)
- `hostpci0: 0000:01:00,pcie=1` (GTX 1080, IOMMU grp 13, vfio-pci), `cpu: host`, `cores: 24`,
  `vga: none`, OVMF, **memory 24576 / balloon 0**.
- NVIDIA driver **582.66** (last Pascal branch). NVENC h264+hevc OK (AV1 unsupported — Pascal).
- **Apollo v0.4.6** (ClassicOldSong fork). Service `ApolloService`. Config dir
  `C:\Program Files\Apollo\config\` (sunshine.conf, apps.json, sunshine.log). Bundled **SudoVDA**
  virtual display (gpuName pinned to the 1080 via `HKLM\SOFTWARE\SudoMaker\SudoVDA\gpuName`).
- **ViGEmBus 1.22.0** installed (gamepad).
- `sunshine.conf` currently: `encoder=nvenc`, `headless_mode=enabled`,
  `adapter_name=NVIDIA GeForce GTX 1080`, `dd_configuration_option=ensure_only_display` (can drop),
  `min_log_level=debug` (set back to `info` for production).
- **Auto-login**: Winlogon `AutoAdminLogon=1`, `DefaultUserName=abl030`, `DefaultDomainName=Gaming-106`,
  `DefaultPassword=ApolloGaming2026!`; `NoLockScreen=1`; lock-on-wake off. (Credential Guard is NOT
  running on this VM, so it doesn't strip auto-login — but on a VM where CG runs, set
  `RequirePlatformSecurityFeatures=0` etc. or 24H2 strips it.)
- **HAGS off** (HwSchMode=1) — harmless, leave it.
- **NIC offloads OFF** (THE FIX — see top).

## Network / isolation / VPN (re-enable — see Current State)
- Static IP **192.168.1.111** via pfSense DHCP reservation, MAC `BC:24:11:5E:E5:00`.
- Proxmox firewall group **`apollo_vpn`** in `/etc/pve/firewall/cluster.fw` + per-VM `110.fw`. Blocks
  VM→LAN (all RFC1918 + 100.64/10 except gateway DNS/DHCP), allows **OUT UDP 47998:48010 to/from LAN
  (streaming return — needed)**, allows LAN/tailnet IN on 22 + 47984/47989/47990/48010 TCP +
  5353/47998:48010 UDP, allows VM→internet.
- VPN egress: pfSense LAN policy-route **pos 29 (pass src .111 → gw AirVPN_SG) + 30 (block kill-switch)**
  — currently DISABLED. AirVPN_SG actually exits **Netherlands** (naming quirk; user OK). Re-enable via
  pfsense subagent, no state flush. Apply VPN AFTER downloads (VPN throttles).
- **Caddy** `apollo.ablz.au → https://192.168.1.111:47990` (skip-verify), internal-only, in
  `~/DotFiles/Caddy/Caddyfile` on host `caddy` (192.168.1.6). Reload non-root via
  `caddy reload --config /etc/caddy/Caddyfile` (no passwordless sudo there; `caddy validate` fails
  non-root — use `caddy adapt`).

## The autonomous test LOOP (for future debugging — this worked)
- **Trigger** (drives framework's Moonlight headlessly-ish on its real screen; framework = NixOS GNOME
  Wayland, 192.168.1.37, paired, uid 1000):
  `ssh framework 'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland timeout 20 moonlight stream 192.168.1.111 Desktop' &`
  (offscreen `QT_QPA_PLATFORM=offscreen` works for `moonlight list` but CAN'T sustain a stream —
  needs the real Wayland display). `ssh framework` has NO passwordless sudo; non-sudo only. framework
  client logs also ship to **Loki** `{host="framework"}`.
- **Eval (the good one)**: packet-capture what the VM EMITS — this is what found the fix:
  `ssh root@192.168.1.12 'timeout 18 tcpdump -ni tap110i0 -w /root/v.pcap "udp and host 192.168.1.37"'`
  then count `packets >1000 bytes` and total bytes. **Working = thousands of large packets + multi-MB.
  Broken (blank) = ~8 large packets + ~14 KB.**
- Screenshot what's actually captured (proved the desktop renders): a Run-key resident PS using
  `System.Windows.Forms`/`System.Drawing` `CopyFromScreen` of the VirtualScreen → PNG → scp to doc1 →
  `Read` the image. (GDI CopyFromScreen sees the desktop fine; Apollo uses DXGI — both were fine.)

## Diagnostic cheatsheet
- Apollo log `C:\Program Files\Apollo\config\sunshine.log`. Key: `Virtual Display created at`,
  `Desktop resolution [WxH]`, `NvEnc: idr frame`, `is_user_session_locked`, `CLIENT CONNECTED/DISCONNECTED`.
- framework Moonlight `Decoded frame with POC` (sparse logging — low count ≠ stall).
- Loki: `https://loki.ablz.au/loki/api/v1/query_range` `{host="framework"}`.

## Research sources (the winning one)
- **LizardByte Discussion #416** — Black Screen/Disconnection on Proxmox VMs: disable **UDP
  Segmentation Offload**, lower MTU ~1400, or switch VirtIO→**E1000E**. THIS WAS THE FIX.
- Sunshine troubleshooting (MTU 1428). Apollo FAQ/discussions #169/#211/#1186 (24H2 set-primary
  broken — turned out irrelevant once auto-login on). Sunshine #345 (auto-login required, locked=black).

## Pairing instructions for the user / clones (no sysprep = pair once, works on all clones)
Moonlight/Artemis → add `192.168.1.111` (or auto-discover `Gaming-106`) → PIN → enter at
`https://apollo.ablz.au` (admin / `nx6mlZQUZdgvzNl4`) → stream **Desktop**.
