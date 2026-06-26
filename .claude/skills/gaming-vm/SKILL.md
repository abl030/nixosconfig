---
name: gaming-vm
description: Spin up and manage Apollo/Sunshine gaming Windows VMs on the prom hypervisor — clones of the GTX-1080-passthrough golden template, one per game, streamed via Moonlight/Artemis. Use when the user wants a new gaming VM, another gaming VM, a VM "for <game>", or to start/switch/stop/list/destroy their gaming VMs. Single GPU = one runs at a time. Trigger phrases include "new gaming vm", "spin up a gaming vm", "gaming vm for <game>", "make me a windows gaming vm", "another gaming machine", "start the <game> vm", "switch to <game>", "list gaming vms", "stop the gaming vm", "destroy the <game> vm".
version: 1.2.0
---

# Gaming VM — clone & manage Apollo Windows gaming VMs

**Use your judgment, not a recipe-by-rote.** Every concrete value below (VMIDs,
the template name, the GPU address, who's paired) is *current as of 2026-06-26
(golden template **v2**, VMID `118`)* and **will drift**. Always discover live
state with `qm` first; treat the numbers here as a description of intent, and
reconcile against what you find. Full backstory + the multi-hour debug saga that
produced this template: `docs/wiki/services/apollo-gaming-vm.md` (read it if
anything is surprising).

## The model (why it's built this way)

- **One golden template**, a fully-configured Windows 11 **Pro 24H2** VM with the
  GTX 1080 passed through, Apollo (Sunshine fork) installed + paired, auto-login
  on, the **NIC offloads disabled** (the one fix that makes streaming work on
  virtio/Proxmox — do not undo it), **Windows fully updated + activated (MAS
  HWID)**, **windows-mcp** (GUI-automation server, autostarts) and **VB-CABLE**
  (audio sink) baked in. Currently **VM `118` "WindowsGamingTemplate-v2"** on the
  `Test` lvmthin pool (= the Crucial T700, a single PCIe-Gen5 NVMe; *not* the
  `nvmeprom` ZFS pool). Find it live: `qm list` → the `template:1` entry named
  `WindowsGamingTemplate-v2`. **⚠️ The OLD VMID `119` "WindowsGamingTemplate" is
  legacy v1** (no windows-mcp / no VB-CABLE / not updated) — if both still exist,
  clone **v2 (118)**, not 119.
- **Per-game clones, kept around.** The user makes a clone per game and keeps a
  few. Clones are **linked clones** of the template (fast, space-cheap on
  lvmthin). De-linking is a *templating* concern only — never needed when cloning.
- **Single GPU → strictly one-at-a-time.** Only one VM can hold `0000:01:00` at
  once. Before starting any gaming VM you MUST stop every other VM that has that
  GPU — **including the user's older non-Apollo game VMs** (e.g. BaldursGate,
  KingdomComeD2, Batocera), not just Apollo clones. `qm start` will fail with the
  GPU in use otherwise.
- **Shared MAC `BC:24:11:5E:E5:00` on every Apollo clone — on purpose.** That MAC
  maps to a pfSense DHCP reservation → **`192.168.1.111`** → the VPN-egress +
  kill-switch + LAN-isolation rules all ride along automatically. Because only
  one clone runs at a time there's no conflict. **So: never randomise a clone's
  MAC, and never touch pfSense per clone** — the whole design is "pfSense is
  untouched; the MAC carries the policy."
- **No sysprep — pairing is baked in.** Every clone has the same SID / hostname
  (`Gaming-106`) and the **same Apollo pairings** (framework, epi, phone, the
  Shield — whoever was paired when the template was made). So a fresh clone is
  immediately streamable by any already-paired client with **no new pairing**.
- **Isolation per clone:** a `/etc/pve/firewall/<vmid>.fw` referencing the
  `apollo_vpn` Proxmox firewall group (in `cluster.fw`). It blocks VM→LAN lateral
  movement, allows the streaming ports + gateway DNS, and the VM's internet
  egress exits via the VPN (lands in NL).
- **Audio: VB-CABLE virtual cable (in Windows) is the captured sink.** The
  template keeps the VM-level Intel-HDA device (`audio0: device=ich9-intel-hda,
  driver=none`) as a fallback render endpoint, but the production audio path is
  **VB-CABLE**: `CABLE Input (VB-Audio Virtual Cable)` is set as abl030's **default
  playback device**, and Apollo's `sunshine.conf` has `audio_sink = CABLE Input
  (VB-Audio Virtual Cable)`. Games play to CABLE Input (default) → Apollo
  loopback-captures CABLE Input → streams. Verified on a live stream: `Selected
  audio sink: CABLE Input` → `Opus initialized`. All baked into the template;
  clones inherit it — nothing to do per clone. (Why VB-CABLE over the bare
  null-backend HDA sink: the headless null-backend's jittery software clock was a
  suspected audio-stutter source; the *actual* stutter fix turned out to be
  client-side — `hosts/common/realtime-audio.nix` rtprio on the Linux Moonlight
  clients — but VB-CABLE gives a clean software-clocked sink and is what's proven.)
- **windows-mcp (GUI automation for installers), baked in.** A `windows-mcp` SSE
  server autostarts in abl030's session 1 and binds `0.0.0.0:8765`, reachable from
  **doc1 only** (`http://192.168.1.111:8765/sse`, bearer
  `wKRrAi5MN9OmJsP81UYrXhy_9vftpYG3QBRnSeqt0NI`, plus `--ip-allowlist 192.168.1.29`).
  The `8765`-from-`.29` pinhole now lives in the **`apollo_vpn` group** (in
  `cluster.fw`), so every clone inherits it — no per-clone firewall work. Use it to
  drive GUI-only game installers (FitGirl etc.) that can't be scripted. See the
  **windows-mcp** section below for how to connect + the click-elevation gotcha.

## Where this runs

All hypervisor ops are `qm` / `pve-firewall` on **prom** (`ssh root@192.168.1.12`,
which doc1 holds). Windows-side checks go through the guest agent
(`qm guest exec <vmid> -- powershell.exe ...`); for multi-line PowerShell use
`-EncodedCommand <base64-of-UTF16LE>` to dodge nested-quote hell. Apollo's admin
UI (for pairing a *new* client) is `https://apollo.ablz.au` or
`https://192.168.1.111:47990` (admin / the password in the knowledge doc).

## Step 0 — always: discover live state

```bash
P="root@192.168.1.12"
ssh $P 'qm list'                                   # all VMs + status
# the template = template:1 with a "Gaming" name (prefer "WindowsGamingTemplate-v2"
# = VMID 118; the bare "WindowsGamingTemplate" = legacy v1/119, do NOT clone it):
ssh $P 'for v in $(qm list|awk "NR>1{print \$1}"); do qm config $v 2>/dev/null|grep -q "^template: 1" && echo "$v $(qm config $v|sed -n s/^name:\ //p)"; done'
# everything holding the single GPU (find the GPU addr from the template's hostpci0):
ssh $P 'for v in $(qm list|awk "NR>1{print \$1}"); do qm config $v 2>/dev/null|grep -qE "^hostpci0:.*01:00" && echo "$v $(qm config $v|sed -n s/^name:\ //p) [$(qm status $v|awk "{print \$2}")]"; done'
```
From that you know: the real template VMID, which VMs contend for the GPU and
which are running, and which VMIDs are free. Decide from *this*, not from memory.

## Create a new per-game VM

1. **Pick a name + free VMID.** Name it for the game, e.g. `apollo-<game>`. Take
   the lowest free VMID in a sensible gaming band (120–149 is the convention;
   adapt if occupied). Confirm it's free in the `qm list` you just pulled.
2. **Free the GPU:** stop every *running* GPU VM from Step 0 (`qm shutdown <v>
   --timeout 90`, fall back to `qm stop`). Tell the user which you stopped.
3. **Linked-clone the template:** `qm clone <template> <newid> --name apollo-<game>`.
4. **Set the shared MAC:** `qm set <newid> -net0 virtio=BC:24:11:5E:E5:00,bridge=vmbr0,firewall=1`.
5. **Write its firewall file** and compile:
   ```bash
   ssh $P 'cat > /etc/pve/firewall/<newid>.fw' <<'FW'
   [OPTIONS]

   enable: 1
   policy_in: DROP
   policy_out: ACCEPT

   [RULES]

   GROUP apollo_vpn
   FW
   ssh $P 'pve-firewall compile'
   ```
6. **Boot:** `qm start <newid>` (the PCI-reset "Inappropriate ioctl" warning is
   benign for passthrough — ignore it).
7. **Verify** (next section).
8. **Update Windows fully, THEN re-activate (do this before installing any game).**
   The clone inherits the template's state, but weeks of CVEs accrue and a fresh
   SMBIOS uuid usually drops HWID activation — so for a box that will run cracked
   binaries (even jailed), patch first, then re-activate:
   - **Windows Update (loop until clean), as SYSTEM** — deploy a self-driving
     `ONSTART`/SYSTEM scheduled task that loops scan→install→reboot via
     PSWindowsUpdate, writing a status file you poll (a single `qm guest exec` only
     gets ~30 s, so don't run it inline). Confirm done with the authoritative online
     scan: `(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()`
     `.Search("IsInstalled=0 and IsHidden=0").Updates.Count` → `0`.
   - **Activate with MAS — use `/KMS38`, NOT `/HWID`, on a clone.** HWID has to
     reach Microsoft's activation servers, which **reject the clone's AirVPN NL
     egress** → HWID fails behind the VPN (confirmed in the RDR2 test). `/KMS38` is a
     **fully offline** activation (valid to 2038; Pro/Ent only — this image is Pro)
     and works behind the VPN, as SYSTEM:
     `&([ScriptBlock]::Create((irm https://get.activated.win))) /KMS38` (set TLS 1.2
     first; `irm get.activated.win` is a WAN/CDN fetch, still reachable). Verify:
     `SoftwareLicensingProduct … LicenseStatus` → `1` (Licensed). (`/HWID` only works
     where the VM has *direct* WAN — e.g. the template build on a non-`.111` MAC,
     which is how the template itself is HWID-activated.)
   - Then clean up the scheduled task + scratch dir before moving on.
9. **Hand off:** stream from any already-paired client (Moonlight/Artemis) →
   host `192.168.1.111` (auto-discovers as `Gaming-106`) → **Desktop**. No new
   pairing needed. Only pair (PIN at `apollo.ablz.au`) if it's a brand-new client.
   - ⚠️ **Client app-list cache (flip side of "no new pairing").** Because every
     clone shares the same identity (`Gaming-106` / cert / UUID / `.111`), a
     paired client **caches the app list per-host** and keeps showing the *previous*
     clone's tiles (and may accumulate duplicate `.111` host records) until the user
     opens the Moonlight **GUI** and re-selects the host, which refreshes the list.
     The headless `moonlight list`/`stream` CLI reads the stale cache and will
     **not** see a new clone's tiles. So **validate a freshly-added tile by clicking
     it in the Moonlight GUI**, not via the CLI — a CLI "0 packets / no CONNECT" on a
     new tile is usually this cache, not a server fault (Desktop still streams fine).

## windows-mcp — GUI automation for game installers

The template bakes a **windows-mcp** SSE server (autostarts as abl030 in session 1,
binds `0.0.0.0:8765`). Use it to click through GUI-only installers (FitGirl repacks,
launchers) that `qm guest exec` can't script. Reachable **from doc1 only**:
`http://192.168.1.111:8765/sse`, header `Authorization: Bearer
wKRrAi5MN9OmJsP81UYrXhy_9vftpYG3QBRnSeqt0NI` (no-auth → 401; the `8765`-from-`.29`
pinhole is in the `apollo_vpn` group so every clone has it). Add it as an MCP server
(SSE transport) to drive Screenshot/Click/Type tools against the live desktop.

**The one gotcha that matters — UIPI / integrity levels.** windows-mcp runs at
**medium** integrity (abl030, non-elevated). It **cannot** send input to a
`requireAdministrator` (elevated/high-IL) window — clicks silently no-op. Most game
installers and `VBCABLE_Setup` are elevated. Ways through (pick by task):
- **For driving a game installer with windows-mcp's *own* Click/Snapshot tools (the
  simplest, validated in the RDR2 test):** temporarily disable UAC so the Run-key
  server itself comes up **High** integrity — `reg add
  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t
  REG_DWORD /d 0 /f` then **reboot**. Now windows-mcp (relaunched by the Run-key)
  runs High and can inject clicks/keys into the elevated installer directly (the
  RDR2 FitGirl wizard was driven this way — mostly `Enter` for Next/Install plus a
  few targeted clicks). When the install is done, **restore `EnableLUA=1` + reboot**
  to return the clone to template posture. (Cleaner than the `-Verb RunAs` dance the
  wiki floats.)
- **Run the click logic as an elevated session-1 process** (no windows-mcp). A
  scheduled task `schtasks /Create /RU abl030 /IT /RL HIGHEST` runs abl030
  **elevated** in the interactive desktop *without* a UAC prompt (scheduled-task
  elevation property). From there, `Start-Process` of the elevated installer + a
  coordinate `mouse_event` click (or UIAutomation `Invoke`) lands, because both are
  high-IL on the same desktop. **This is the deterministic path for the template's
  own build steps** (it's how VB-CABLE was installed — see the rebuild section).
- **From windows-mcp itself, without disabling UAC:** set
  `ConsentPromptBehaviorAdmin=0` and have its PowerShell tool relaunch a `-Verb
  RunAs` elevated helper that does the clicking.
- **Session 0 is a dead end:** a SYSTEM task (`qm guest exec` context) launches GUI
  apps on the hidden session-0 desktop — UIAutomation there finds *nothing*. The
  clicker must be in **session 1**.
- **Custom-drawn UIs expose no controls.** Some installers (e.g. VB-CABLE) are a
  single painted window: `EnumChildWindows` and UIAutomation both return zero
  descendants. Fall back to **screenshot → read the PNG → click by coordinates**
  relative to the window's live bounding rect (the window's Y drifts between runs,
  so always recompute from `BoundingRectangle`, never hard-code absolute Y).

## Install a game on a clone (FitGirl repacks etc.)

The skill used to start at "once a game is installed" — this section closes that
gap (added from the RDR2 e2e test). Do this on the clone **after** Windows Update +
KMS38 activation, **before** the tile step.

### 1. Get the repack files onto the clone

The clone is **LAN-isolated** (`apollo_vpn` does `OUT DROP 192.168.0.0/16`), so it
**cannot reach the NAS/SMB share** where games live (e.g. `\\192.168.1.2\data` =
tower Unraid; on prom it's the CIFS mount `/mnt/pve/Tower`, creds in
`/etc/pve/priv/storage/Tower.pw`). Two ways in:

- **A — copy IN over the clone's SSH:22 (firewall-clean, preferred).** `apollo_vpn`
  already allows inbound `22` from the LAN, so push the repack onto the clone from a
  host with normal LAN access (doc1 can read the tower share AND `ssh`/`scp` to the
  clone): `scp -i <key> "<repack dir>" abl030@192.168.1.111:'C:/Games/<game>/'`. **No
  firewall edit; the clone never reaches out.** (This is the user's preferred method.)
- **B — let the clone PULL via SMB (what the RDR2 test did; direct, one hop).** Add a
  **narrow temporary** per-VM rule *above* the group so the clone can reach only the
  share host on 445, then `robocopy` from `\\192.168.1.2\data\...` (~95 MiB/s), then
  **remove the rule and re-verify isolation**:
  ```bash
  # prepend to /etc/pve/firewall/<vmid>.fw [RULES], ABOVE "GROUP apollo_vpn":
  #   OUT ACCEPT -dest 192.168.1.2 -p tcp -dport 445 -log nolog # TEMP: game copy
  ssh $P 'pve-firewall compile'            # robocopy from the guest, then:
  # delete that one line, recompile, and RE-CHECK isolation from the guest.
  ```
  ⚠️ **`pve-firewall compile` is not instant** — the daemon takes **~20 s** to apply,
  so the port stays open briefly after you remove the rule. Wait, then confirm the
  guest can no longer reach `192.168.1.2:445` before trusting that isolation is back.

Mind disk space: a clone's disk is 300 GB; a big repack needs the source **plus** the
install (~2×) during the run — e.g. RDR2 = 67 GB repack → 116.8 GB installed. **Delete
the source repack after install.**

### 2. Run the installer — FitGirl is GUI-only

`setup.exe /VERYSILENT /SUPPRESSMSGBOXES` **aborts** ("error reading source file")
— FitGirl repacks require the interactive wizard. Drive it via **windows-mcp** (see
that section: `EnableLUA=0` + reboot so the server is High-integrity, then mostly
`Enter` for Next/Install plus a few targeted clicks; restore `EnableLUA=1` + reboot
after). Expect a **long** decompress (RDR2 ≈ 51 min on 24 cores) and a default
"verify integrity" CRC pass at the end. At Finish the installer pulls DirectX legacy
+ VC++ redists over the VPN; a **.NET 3.5** on-demand prompt may pop (skip unless the
game needs it); VC++ "already installed (0x80070666)" is benign.

## Add a per-game tile (one-click launch in Moonlight)

Once a game is installed on a clone, give it its own Moonlight tile so the user
picks the game and lands straight in it (no Desktop → hunt → launch). This is a
**per-clone, post-install** step — the game lives on that clone's disk, so the
tile is added to *that VM's* Apollo, not the template.

1. **Find the launcher.** FitGirl/most installers drop a desktop shortcut —
   resolve its target:
   ```powershell
   (New-Object -ComObject WScript.Shell).CreateShortcut("C:\Users\abl030\Desktop\<Game>.lnk").TargetPath
   ```
   (or search `C:\Games`). Note the `.exe` and its folder (the working dir).
2. **Grab cover art (keyless, from Steam).** It makes the tile look right:
   ```bash
   curl -s "https://store.steampowered.com/api/storesearch/?term=<game>&cc=us&l=en"   # → items[].id (appid)
   curl -s "https://store.steampowered.com/api/appdetails?appids=<appid>&cc=us&l=en"  # → .data.header_image
   ```
   `header_image` (460×215 key art) always exists. The nicer *vertical* box art is
   `library_600x900.jpg` under the same hashed asset dir — but it's often missing
   for unreleased games (404). SteamGridDB has vertical grids for almost anything
   but needs a free API key. Download the art on doc1, `scp` it to the VM as
   `abl030` (e.g. `C:/Users/abl030/cover.jpg`), then **as SYSTEM** move it into
   `C:\Program Files\Apollo\config\covers\` and point `image-path` at it.
3. **Add the app to `C:\Program Files\Apollo\config\apps.json`.** Apollo rewrites
   that file on shutdown, so **Stop-Service ApolloService first**, edit, start.
   Edit with `ConvertFrom-Json` → append → `ConvertTo-Json -Depth 12` →
   `Set-Content -Encoding ascii` (no BOM); de-dup by `name`, preserve `uuid` on
   re-runs. The app object:
   ```json
   { "name": "<Game>", "cmd": "<...\\game.exe>", "working-dir": "<...\\folder>",
     "elevated": true, "auto-detach": true,
     "image-path": "C:\\Program Files\\Apollo\\config\\covers\\<game>.jpg",
     "uuid": "<new GUID>" }
   ```
   - ⚠️ **`"elevated": true` is REQUIRED for most games.** Apollo launches apps
     non-elevated in the user session; a game whose manifest demands admin (most
     AAA / FitGirl titles) then fails with `Failed to launch process: 740`
     (`ERROR_ELEVATION_REQUIRED`) and **Moonlight shows "Error 0 / Failed to start
     the specified application."** If a tile gives **Error 0, this is almost
     always the cause** — add `elevated: true`.
   - `auto-detach: true` copes with games that fork a launcher and exit.
4. Restart Apollo → the tile (with cover) appears in Moonlight on refresh; clicking
   it launches the game and streams it directly.

## Lock the clone off the internet (optional — ASK the user)

Once a game is installed a clone usually has no further need for WAN, and cutting
it off shrinks the attack surface of a headless, auto-login Windows box running
cracked binaries. **This is per-game and must NOT be automatic** — online games,
launchers, and game updates need the internet. So **after install, ASK:** *"Want
me to cut this VM off the internet now that `<game>`'s installed?"*

If yes, block at the **per-VM** firewall — NOT the shared `apollo_vpn` group, so
other clones / future game installs keep their WAN:
```bash
sed -i 's/^policy_out: ACCEPT/policy_out: DROP/' /etc/pve/firewall/<vmid>.fw
pve-firewall compile
```
The group's explicit allows still fire (DNS-to-gateway, DHCP, LAN streaming), so
the VM keeps streaming and resolving names — only WAN egress is dropped. Verify
from the guest: `Invoke-WebRequest https://1.1.1.1 -TimeoutSec 8` times out while
`Resolve-DnsName cloudflare.com` still works. Reverse anytime with `policy_out:
ACCEPT`. (Note: clones share IP `.111`, so don't block at pfSense or in the group
— that'd hit every clone, including the next one mid-install.)

## Start / switch / stop / list / destroy

- **list:** Step 0's queries — separate Apollo clones (shared MAC) from other GPU
  VMs so the user sees the full one-at-a-time picture.
- **start / switch to `<game>`:** resolve the name→VMID, **stop all other GPU
  VMs**, then `qm start`. Verify if it's an Apollo clone.
- **stop:** `qm shutdown <id> --timeout 90` (clean, so Apollo/Windows flush).
- **destroy:** confirm it's the right VM and **not the template**; `qm shutdown`
  if running, then `qm destroy <id> --purge` and `rm -f /etc/pve/firewall/<id>.fw`
  (+ `pve-firewall compile`). Be especially careful destroying a *non-Apollo* GPU
  VM (the user's older game VMs) — name it back to the user before you do.

## Verify a running clone

Lightweight health check via the guest agent (expect all green):
- **IP is `192.168.1.111`** — confirms the shared-MAC DHCP reservation took
  (`Get-NetIPAddress` / wait for the agent first; Windows takes ~60–90 s to boot
  + auto-login).
- **Auto-login:** `(gcim Win32_ComputerSystem).UserName` → `Gaming-106\abl030`.
- **Apollo up:** `(Get-Service ApolloService).Status` → Running.
- **Offloads off:** `Get-NetAdapterAdvancedProperty | ? DisplayName -match 'UDP
  Segmentation'` → Disabled (the streaming fix; if this is on, streaming will be
  a black screen).
- **GPU/NVENC:** `& "$env:windir\System32\nvidia-smi.exe" --query-gpu=name,driver_version --format=csv,noheader` → GTX 1080.
- **VPN exit:** `Invoke-RestMethod https://ipinfo.io/json` → country `NL`.
- **LAN isolation:** `Test-Connection 192.168.1.29 -Count 1 -Quiet` → `False`
  (apollo_vpn blocks VM→LAN).
- **Audio (VB-CABLE):** default playback = `CABLE Input (VB-Audio Virtual Cable)`
  (`Import-Module AudioDeviceCmdlets; (Get-AudioDevice -Playback).Name`), and on a
  live stream the Apollo log shows `Selected audio sink: CABLE Input` + `Opus
  initialized` (NOT `Couldn't get default audio endpoint` / `no audio`).
- **windows-mcp:** `Get-NetTCPConnection -LocalPort 8765 -State Listen` is true in
  the guest, and from doc1 `curl -m5 http://192.168.1.111:8765/sse` → `401`, with
  the bearer header → `200`.
- **Activation:** `SoftwareLicensingProduct (…Pro…) LicenseStatus` → `1` (Licensed).
  A fresh clone often needs MAS re-run (step 8) — a new SMBIOS uuid drops HWID.

Deep proof (only if asked, or if a client reports a black screen) — packet-count
what the VM actually emits while a real client streams. framework is a paired
test client on the LAN:
```bash
ssh $P 'timeout 28 tcpdump -ni tap<newid>i0 -w /tmp/v.pcap "udp and host 192.168.1.37"' &
ssh framework 'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland timeout 20 moonlight stream 192.168.1.111 Desktop'
ssh $P 'tcpdump -nr /tmp/v.pcap "greater 1000" | wc -l; ls -l /tmp/v.pcap'
```
Working = thousands of >1000-byte packets + multi-MB pcap, with `…111.47998 > …`
length-1408 video. Broken (offloads back on / locked session) = ~8 packets, ~14 KB.

## Rebuilding the golden template (the v2 recipe)

How v2 (`118`) was built, 2026-06-26, from v1 (`119`) — follow this to make a v3.
Build on a **non-`.111` MAC** so WAN egress is direct (the VPN throttles downloads);
switch to the shared MAC only at the very end.

1. **Full-clone the current template** (de-links it): `qm clone 119 <buildid> --full
   --name WindowsGamingTemplate-vN`. A full clone gets a fresh random MAC → normal
   DHCP + direct WAN (good for the build). Write `<buildid>.fw` = `apollo_vpn` group
   with `policy_out: ACCEPT`; `pve-firewall compile`; `qm start`.
2. **Windows Update, fully** (SYSTEM, looped task → poll a status file; confirm `0`
   via the online COM scan — see step 8 of "Create a new per-game VM").
3. **Activate** (SYSTEM): MAS `/HWID`; verify `LicenseStatus=1`.
4. **windows-mcp** — two phases:
   - *admin (SYSTEM):* install system **Python 3.13** all-users to `C:\Program
     Files\Python313`; write `C:\Users\abl030\start-winmcp.cmd` (runs
     `%USERPROFILE%\.local\bin\windows-mcp.exe serve --transport sse --host 0.0.0.0
     --port 8765 --ip-allowlist 192.168.1.29 --auth-key <TOKEN>`); set HKU\<abl030
     SID>\…\Run\WindowsMCP = `cmd /c "…start-winmcp.cmd"`; create two firewall allow
     rules (TCP 8765 from `192.168.1.29`: one `Program Any`, one
     `Program C:\Program Files\Python313\python.exe`) and delete any auto-created
     inbound python **Block** rules.
   - *user (abl030, `/IT` task):* install `uv` (`irm https://astral.sh/uv/install.ps1
     | iex`) then `uv tool install windows-mcp --python "C:\Program
     Files\Python313\python.exe"`.
   - Reboot; confirm `:8765` listening + doc1 `curl` 401/200.
5. **VB-CABLE** (headless): download `VBCABLE_Driver_Pack45.zip`, extract; add the
   VB-Audio signer cert (from `VBCABLE_Setup_x64.exe`) to LocalMachine
   `TrustedPublisher`+`Root`; `pnputil /add-driver vbMmeCable64_win10.inf /install`
   (pre-stages the driver, **no trust prompt**). That stages the driver but does NOT
   create the device — `VBCABLE_Setup_x64.exe` must run + its **"Install Driver"**
   button be clicked. The window is fully custom-painted (no child HWNDs / no UIA
   controls), so: an **elevated session-1 task** (`/RU abl030 /IT /RL HIGHEST`)
   launches it, screenshots the window, and clicks **"Install Driver"** by
   coordinates (it sits bottom-right, ≈ `(windowX+755, windowY+405)` in the 820×432
   window). Reboot to finalize.
6. **Default sink + Apollo** : install `AudioDeviceCmdlets` (AllUsers); as abl030,
   `Set-AudioDevice` the `CABLE Input (VB-Audio Virtual Cable)` playback device;
   add `audio_sink = CABLE Input (VB-Audio Virtual Cable)` to `sunshine.conf` and
   restart `ApolloService`.
7. **Verify everything** with the running-clone checklist (do a real framework
   stream — video pkt-count + Apollo `Selected audio sink: CABLE Input`).
8. **Clean build cruft**: delete every `schtasks` task you created + the scratch
   dirs (`C:\mcpsetup`, `C:\vbcable`, `C:\winupdate`); keep windows-mcp / Python /
   `start-winmcp.cmd` / Run-key / firewall rules.
9. **Shared MAC + template**: `qm shutdown`; `qm set <buildid> -net0
   virtio=BC:24:11:5E:E5:00,bridge=vmbr0,firewall=1`; `qm start` and re-verify the
   full checklist **as `.111`** (VPN exit NL + LAN isolation). Then `qm shutdown` +
   `qm template <buildid>`.
10. Update this skill's VMID/name, then retire the old template once its linked
    clones are gone.

## Gotchas

- **Two gaming VMs can't run at once** — the GPU is singular. If `qm start`
  errors with the device busy, something else still holds `01:00`; stop it.
- **Don't change a clone's MAC or add pfSense rules.** The shared MAC *is* the
  policy plumbing. A clone with a random MAC won't get `.111` and won't be
  isolated/VPN'd.
- **Linked clones depend on the template.** Don't `qm destroy` the template while
  clones exist (and note v2/118 was a **full** clone of v1/119, so 119 still has
  its own linked children — destroying 119 needs those gone first). To rebuild the
  template, see "Rebuilding the golden template" below.
- **A clone is only as good as the template.** If you ever rebuild/replace the
  template, re-verify (reboot first) offloads-off + auto-login + pairings + the
  VB-CABLE default-sink + windows-mcp autostart + activation all survive before
  trusting it.
- **RAM:** template is 24 GB (`balloon 0`, passthrough pins it). Don't bump a
  clone's RAM without checking prom headroom — overcommitting a pinned VM can OOM
  the hypervisor (it runs the whole fleet). See Forgejo issue #12.
- **windows-mcp clicks elevated windows only from an elevated session-1 process.**
  Medium-IL (the default autostart) can't click installers; SYSTEM/session-0 can't
  see the desktop. Use a `/RU abl030 /IT /RL HIGHEST` task. (Full detail in the
  windows-mcp section.)
- **prom quorum is a single node + a QDevice witness on the `Caddy2.0` VM
  (`192.168.1.6`, on tower).** If that VM is down, prom loses quorum and pmxcfs goes
  **read-only** — every `qm clone` / firewall write fails with `cluster not ready -
  no quorum?` (reads still work from cache). Fix: start `Caddy2.0` on tower (the
  `tower` subagent), confirm `pvecm status` → `Quorate: Yes`. Don't `pvecm expected
  1` blindly — revive the witness.
- **Per clone: re-activate Windows (MAS) after updating — with `/KMS38`, not
  `/HWID`.** A fresh SMBIOS uuid drops the template's HWID license, so the clone
  shows unactivated; but **HWID re-activation FAILS behind the VPN** (MS rejects the
  AirVPN NL egress). Use the offline `/KMS38` on clones (step 8). HWID only works
  with direct WAN (the template build).
- **Driving game installers with windows-mcp:** the medium-IL autostart can't click
  elevated installers. Simplest fix (RDR2-validated): `EnableLUA=0` + reboot →
  windows-mcp comes up High-IL → drives the wizard → restore `EnableLUA=1` + reboot.
  See the windows-mcp + "Install a game" sections.
- **A clone is LAN-isolated, so it can't reach the NAS share to fetch games.** Copy
  IN over its allowed inbound SSH:22, or punch a *temporary* narrow per-VM 445 hole
  and re-verify isolation after (`pve-firewall compile` lags ~20 s). See "Install a
  game on a clone".
- **New-clone tiles are invisible to already-paired clients until the Moonlight GUI
  refreshes** the per-host app list (shared identity → cached list). Validate a new
  tile in the GUI, not the headless CLI.
