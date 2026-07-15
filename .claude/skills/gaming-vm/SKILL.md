---
name: gaming-vm
description: Spin up and manage Apollo/Sunshine gaming Windows VMs on the prom hypervisor — clones of the GTX-1080-passthrough golden template, one per game, streamed via Moonlight/Artemis. Use when the user wants a new gaming VM, another gaming VM, a VM "for <game>", or to start/switch/stop/list/destroy their gaming VMs. Single GPU = one runs at a time. Trigger phrases include "new gaming vm", "spin up a gaming vm", "gaming vm for <game>", "make me a windows gaming vm", "another gaming machine", "start the <game> vm", "switch to <game>", "list gaming vms", "stop the gaming vm", "destroy the <game> vm".
version: 1.3.0
---

# Gaming VM — clone & manage Apollo Windows gaming VMs

**Use your judgment, not a recipe-by-rote.** Every concrete value below (VMIDs,
the template name, the GPU address, who's paired) is *current as of 2026-06-26
(golden template **v3**, VMID `117`)* and **will drift**. Always discover live
state with `qm` first; treat the numbers here as a description of intent, and
reconcile against what you find. Full backstory + the multi-hour debug saga that
produced this template: `docs/wiki/services/apollo-gaming-vm.md` (read it if
anything is surprising).

## The model (why it's built this way)

- **One golden template**, a fully-configured Windows 11 **Pro 24H2** VM with the
  GTX 1080 passed through, Apollo (Sunshine fork) installed + paired, auto-login
  on, the **NIC offloads disabled** (the one fix that makes streaming work on
  virtio/Proxmox — do not undo it), **Windows fully updated**, **windows-mcp**
  (GUI-automation server, autostarts), **VB-CABLE** (audio sink), and — new in v3 —
  **all the game-install prerequisites pre-baked so installs need NO internet**:
  VC++ redists (2008–2022, x64+x86), the DirectX June-2010 legacy runtime
  (d3dx9/11, xinput, xaudio), and .NET 3.5. **UAC stays ON** (a real guard if a
  cracked binary misbehaves — drive elevated installers via the elevated-session-1
  task, see windows-mcp section). Currently **VM `117` "WindowsGamingTemplate-v3"**
  on the `Test` lvmthin pool (= the Crucial T700, a single PCIe-Gen5 NVMe; *not* the
  `nvmeprom` ZFS pool). Find it live: `qm list` → the highest-version `template:1`
  entry named `WindowsGamingTemplate-v*`. **Clone the newest — v3 / `117`.** (The
  older v1/`119` and v2/`118` templates were both **DELETED 2026-06-26**, along with
  the RDR2 test clone `121 apollo-rdr2`; `117` is the only gaming template now, and
  the only other gaming VM is `120 apollo-007-first-light`.)
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
# the template = template:1 with a "Gaming" name. Clone the NEWEST version:
# "WindowsGamingTemplate-v3" = VMID 117 (deps baked) — the ONLY gaming template now (v1/119 + v2/118 deleted 2026-06-26).
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
   A `qm clone` gets a **fresh random MAC** → a normal DHCP lease → **direct WAN**
   (not the AirVPN tunnel). **Leave it on this MAC for now** — Windows activation
   needs direct WAN (step 6), so the `.111` MAC goes on *after* activation.
4. **Write its firewall file** and compile (the `apollo_vpn` group; on the random MAC
   it still gets WAN egress + LAN-isolation — exactly what we want for update/activate):
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
5. **Boot:** `qm start <newid>` (the PCI-reset "Inappropriate ioctl" warning is
   benign — ignore it). Confirm it's up (IP will be a dynamic LAN addr, not `.111`).
6. **Update Windows fully, then activate — both need WAN; do them now on the
   direct-WAN MAC.** (Activation is cosmetic — games run unactivated — so this whole
   step is optional; skip it and you can set the `.111` MAC before first boot instead.)
   - **Windows Update (loop until clean), as SYSTEM** — a self-driving `ONSTART`/SYSTEM
     scheduled task that loops scan→install→reboot via PSWindowsUpdate, writing a
     status file you poll (`qm guest exec` only gets ~30 s, don't run it inline).
     Confirm with the online scan: `(New-Object -ComObject Microsoft.Update.Session)`
     `.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0").Updates.Count` → 0.
     **Updater edge case:** after successfully installing a cumulative update,
     `PSWindowsUpdate` can throw `0x80248007` because its data-store view was
     invalidated while Windows is already marked reboot-pending. Before treating that
     as failure, check `Get-WURebootStatus -Silent` plus the CBS/WindowsUpdate
     `RebootPending` registry keys; if any are set, reboot and let the ONSTART task
     continue. Verify success only with the fresh post-reboot COM scan.
   - **Activate with MAS HWID (online).** ⚠️ **KMS38 is DEAD** — MS removed
     `gatherosstate.exe` (build 26040) and fully deprecated KMS38 at **26100.7019**, so
     `/KMS38` silently no-ops on our build (don't use it). **HWID is the only option and
     it's ONLINE** — it must reach MS activation servers from an IP they accept; the
     **AirVPN NL exit is rejected**, which is the whole reason we activate here on the
     direct-WAN MAC. Run as SYSTEM, bypassing the loader's `-Verb RunAs` (it detaches
     headless) by running the AIO directly:
     ```powershell
     $u='https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/<commit>/MAS/All-In-One-Version-KL/MAS_AIO.cmd'
     irm $u -OutFile C:\MAS_AIO.cmd
     Start-Process $env:ComSpec -ArgumentList '/c','C:\MAS_AIO.cmd','-el','/HWID' -Wait -NoNewWindow
     ```
     Verify `LicenseStatus` → `1` ("permanently activated with a digital license"),
     then delete `C:\MAS_AIO.cmd`. (HWID is hardware-tied to the SMBIOS uuid → survives
     MAC changes + reboots; a *new* clone's new uuid drops it → re-activate per clone.)
7. **Now apply the shared `.111` MAC** (needs a fresh QEMU start, so shut down cleanly
   and **let the GPU settle** first — never thrash the reset):
   `qm shutdown <newid> --timeout 120`; wait ~30 s; `qm set <newid> -net0
   virtio=BC:24:11:5E:E5:00,bridge=vmbr0,firewall=1`; `qm start <newid>`.
8. **Verify** (next section) — now `.111`, VPN exit NL, LAN-isolated, activated.
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
installers and `VBCABLE_Setup` are elevated. **UAC stays ON** on these VMs (user's
call — it's a real guard if a cracked binary misbehaves), so **do NOT disable it**.
Ways through:
- **THE method — run the click logic as an elevated session-1 process.** A scheduled
  task `schtasks /Create /TN drive /TR '...' /SC ONCE /ST 00:00 /RU abl030 /IT /RL
  HIGHEST /F` then `schtasks /Run /TN drive` runs abl030 **elevated** in the
  interactive desktop *without* a UAC prompt (the scheduled-task elevation property).
  That elevated PowerShell `Start-Process`es the installer (also elevated, same
  desktop → no UIPI block) and drives it — UIAutomation `Invoke`, or for
  custom-painted windows a coordinate `mouse_event` click (recompute the button
  position from the window's live `BoundingRectangle`; its Y drifts run-to-run).
  This is how VB-CABLE and the RDR2 FitGirl wizard were driven (mostly `Enter` for
  Next/Install + a few targeted clicks). Keeps UAC on, no reboots.
- **Session 0 is a dead end:** a SYSTEM task (`qm guest exec` context) launches GUI
  apps on the hidden session-0 desktop — UIAutomation there finds *nothing*. The
  clicker must be in **session 1** (hence `/IT`).
- *(Not used here, for reference: you could disable UAC — `EnableLUA=0` + reboot →
  the Run-key windows-mcp comes up High-IL and its own Click/Snapshot drive elevated
  windows — but we deliberately keep UAC on, so use the elevated-task above instead.)*
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
gap. Sequence: do Windows Update + activation **first** (they need WAN), **then CUT
WAN PERMANENTLY** (see "Cut the clone off the internet" below), **then** install the
game fully **offline**, then add the tile.

**Why offline works in v3:** the template pre-bakes every common prerequisite (VC++
2008–2022, DirectX June-2010 runtime, .NET 3.5), so a FitGirl installer's "install
prerequisites" step finds them already present and needs **no internet**. The point
is security: the FitGirl installer is an **untrusted cracked binary** — it must run
with **no WAN** so it can't phone home, pull a second stage, or exfiltrate. So the
WAN cut happens **before** the installer launches and is **never** restored.

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

### 2. Run the installer — FitGirl is GUI-only, driven offline

`setup.exe /VERYSILENT /SUPPRESSMSGBOXES` **aborts** ("error reading source file")
— FitGirl repacks require the interactive wizard. Drive it via the **elevated
session-1 task** (UAC stays on — see the windows-mcp section): mostly `Enter` for
Next/Install plus a few targeted clicks. Expect a **long** decompress (RDR2 ≈ 51 min
on 24 cores) and a default "verify integrity" CRC pass at the end. The installer's
prerequisite step (VC++ / DirectX / .NET) is a **no-op** — they're pre-baked in v3,
so it completes with WAN already cut. VC++ "already installed (0x80070666)" is benign;
if a game wants a prereq we *didn't* bake, note it and add it to a template refresh —
**do NOT re-open WAN for the untrusted installer**.

**FitGirl completion/verification gotcha:** extraction completion is not installation
completion. On the final wizard page, leave **Verify files integrity** enabled, disable
website/redirect/game-launch options, click Finish, and wait for `QuickSFV.EXE` to show
`Finished` with all files OK and `Bad: 0 / Missing: 0`. Do not infer completion from
CPU dropping, the game executable existing, or `setup.tmp` becoming idle. A normal SSH
session cannot read the elevated verifier's `MainWindowTitle`; monitor it from an
**elevated session-1 task** (or inspect its screenshot). Only close QuickSFV after the
final counts are recorded, then delete the copied repack source.

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

## Cut the clone off the internet — BEFORE the installer (mandatory)

A FitGirl repack is an **untrusted cracked binary**. Cut the clone's WAN **before you
launch its installer**, and **leave it cut** — the installer (and the game) must never
touch the internet from this jailed, auto-login box. Because v3 pre-bakes the redists/
DirectX/.NET, the offline install just works. (Order: Windows Update + activation need
WAN, so do those first, *then* cut WAN, *then* copy in the repack over the LAN and run
the installer.)

Cut at the **per-VM** firewall — NOT the shared `apollo_vpn` group, so other clones /
future installs keep their WAN until *their* cut:
```bash
sed -i 's/^policy_out: ACCEPT/policy_out: DROP/' /etc/pve/firewall/<vmid>.fw
pve-firewall compile
```
**No exceptions, and the agent never re-opens WAN on its own.** WAN gets cut for the
install, full stop. If the game turns out to **need internet to run** (Rockstar/Steam/
launcher, live-service, online check): do **NOT** enable WAN. **Finish the whole skill
anyway** (install, tile, verify it streams), then — **at the very end** — surface it to
the user as the *last* thing: *"`<game>` wants internet to run; do you want WAN allowed
on this clone?"* and let **them** make the call. Opening a cracked-binary box to the
internet is always the user's decision, never the agent's.
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

## Rebuilding the golden template (the v2/v3 recipe)

How v2 (`118`) was built from v1 (`119`), then **v3 (`117`) from v2** — follow this
to make a v4. **Always full-clone the *current* template (now `117`/v3)** — never a
deleted older one. Build on a **non-`.111` MAC** so WAN egress is direct (the VPN
throttles downloads); switch to the shared MAC only at the very end.

1. **Full-clone the current template** (de-links it): `qm clone 117 <buildid> --full
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
6b. **Bake the game-install deps (v3)** so clones install offline: as SYSTEM,
    silent-install VC++ 2008–2022 (x64+x86), the DirectX June-2010 runtime, and
    enable .NET 3.5. Two gotchas that cost time: (1) **don't name a PowerShell
    function param `$args`** — it's a reserved automatic var, so your install
    arguments arrive empty and every `Start-Process` no-ops; (2) **`DXSETUP.exe`
    needs its working directory set** to the extracted folder (`-WorkingDirectory`),
    or it returns rc=-9 and installs nothing. Verify: `Test-Path
    C:\Windows\SysWOW64\d3dx9_43.dll` + VC++ entries in Uninstall + NetFx3 `Enabled`.
7. **Verify everything** with the running-clone checklist (do a real framework
   stream — video pkt-count + Apollo `Selected audio sink: CABLE Input`).
8. **Clean build cruft**: delete every `schtasks` task you created + the scratch
   dirs (`C:\mcpsetup`, `C:\vbcable`, `C:\winupdate`, `C:\deps`, `C:\deps2`); keep
   windows-mcp / Python / `start-winmcp.cmd` / Run-key / firewall rules.
9. **Shared MAC + template**: `qm shutdown`; `qm set <buildid> -net0
   virtio=BC:24:11:5E:E5:00,bridge=vmbr0,firewall=1`; `qm start` and re-verify the
   full checklist **as `.111`** (VPN exit NL + LAN isolation). Then `qm shutdown` +
   `qm template <buildid>`.
10. Update this skill's VMID/name, then retire the old template once its linked
    clones are gone.

## Gotchas

- **Two gaming VMs can't run at once** — the GPU is singular. If `qm start`
  errors with the device busy, something else still holds `01:00`; stop it.
- **⚠️ Don't thrash the GPU reset.** The GTX 1080 passthrough is reliable when
  cycled **cleanly**: a proper `qm shutdown`, then let the card settle before the
  next `qm start`. What wedges it: (a) `qm shutdown`→`qm set`→`qm start`
  **back-to-back** (e.g. to change the MAC) races the vfio reset → half-reset; and
  (b) **`qm stop`/SIGTERM of a guest hung mid-GPU-init** leaves it stuck (`qm start`
  → `failed to reset PCI device … got timeout`). If wedged: `echo 1 >
  /sys/bus/pci/devices/0000:01:00.{0,1}/remove; echo 1 > /sys/bus/pci/rescan`, then
  rebind to vfio-pci (`driver_override` = `vfio-pci`, bind). If even that won't reset
  it, the only sure fix is a **prom reboot** (fleet outage — `onboot=1` brings
  doc1/doc2/igpu back). So: never cycle the GPU faster than it can reset, and never
  hard-kill a VM stuck mid-GPU-init.
- **Don't change a clone's MAC or add pfSense rules.** The shared MAC *is* the
  policy plumbing. A clone with a random MAC won't get `.111` and won't be
  isolated/VPN'd.
- **Linked clones depend on the template.** Don't `qm destroy` the template (`117`)
  while linked clones exist — destroy or de-link the clones first. To tell which:
  `lvs -o lv_name,origin` — a clone whose disk shows `origin base-117-disk-*` is
  linked (destroying `117` would fail/orphan it); a clone on `nvmeprom` with no
  origin (like `120`) is independent and safe. To rebuild the template, see
  "Rebuilding the golden template" below.
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
- **prom is a standalone single-node cluster — no QDevice, no witness** (the old
  `Caddy2.0` QDevice was removed 2026-07-02). `qm clone` / `pct` / firewall writes
  just work; you do NOT need to start anything on tower for quorum. If prom is ever
  non-quorate now, that's a NEW fault — do not `pvecm expected 1` blindly; the
  local-mode recovery recipe + full history are in
  `docs/wiki/infrastructure/prom-hypervisor.md` → *Cluster / quorum*.
- **Activation: HWID-online only; KMS38 is DEAD.** Microsoft removed
  `gatherosstate.exe` (build 26040) and **fully deprecated KMS38 at build 26100.7019**
  — on our 26100.8655 `/KMS38` silently no-ops (this is why early attempts "ran" with
  exit 0 but never licensed). So the **only** method is **HWID, which is online** and
  needs a Microsoft-accepted IP. The clone's **AirVPN NL exit is rejected**, so HWID
  must run on a **direct-WAN** MAC (a fresh `qm clone`'s random MAC) *before* the
  `.111` MAC is applied (step 6). Run the AIO directly as SYSTEM (`MAS_AIO.cmd -el
  /HWID`) — the `irm | iex` loader's `-Verb RunAs` detaches in a headless context and
  no-ops. Verified working on 120 (007) over the AU residential IP. Activation is
  cosmetic (games run unactivated) so it never blocks the build; HWID is hardware-tied
  (SMBIOS uuid), so re-activate per clone.
- **UAC stays ON; drive elevated installers via the elevated session-1 task** (`/RU
  abl030 /IT /RL HIGHEST`), NOT by disabling UAC — it's a deliberate guard against
  misbehaving cracked binaries. (Full detail in the windows-mcp section.)
- **A clone is LAN-isolated, so it can't reach the NAS share to fetch games.** Copy
  IN over its allowed inbound SSH:22, or punch a *temporary* narrow per-VM 445 hole
  and re-verify isolation after (`pve-firewall compile` lags ~20 s). See "Install a
  game on a clone".
- **New-clone tiles are invisible to already-paired clients until the Moonlight GUI
  refreshes** the per-host app list (shared identity → cached list). Validate a new
  tile in the GUI, not the headless CLI.
