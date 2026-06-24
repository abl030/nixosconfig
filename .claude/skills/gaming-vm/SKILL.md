---
name: gaming-vm
description: Spin up and manage Apollo/Sunshine gaming Windows VMs on the prom hypervisor — clones of the GTX-1080-passthrough golden template, one per game, streamed via Moonlight/Artemis. Use when the user wants a new gaming VM, another gaming VM, a VM "for <game>", or to start/switch/stop/list/destroy their gaming VMs. Single GPU = one runs at a time. Trigger phrases include "new gaming vm", "spin up a gaming vm", "gaming vm for <game>", "make me a windows gaming vm", "another gaming machine", "start the <game> vm", "switch to <game>", "list gaming vms", "stop the gaming vm", "destroy the <game> vm".
version: 1.0.0
---

# Gaming VM — clone & manage Apollo Windows gaming VMs

**Use your judgment, not a recipe-by-rote.** Every concrete value below (VMIDs,
the template name, the GPU address, who's paired) is *current as of 2026-06-24*
and **will drift**. Always discover live state with `qm` first; treat the
numbers here as a description of intent, and reconcile against what you find.
Full backstory + the multi-hour debug saga that produced this template:
`docs/wiki/services/apollo-gaming-vm.md` (read it if anything is surprising).

## The model (why it's built this way)

- **One golden template**, a fully-configured Windows 11 VM with the GTX 1080
  passed through, Apollo (Sunshine fork) installed + paired, auto-login on, and
  the **NIC offloads disabled** (the one fix that makes streaming work on
  virtio/Proxmox — do not undo it). Currently **VM `119` "WindowsGamingTemplate"**
  on the `Test` lvmthin pool (= the Crucial T700, a single PCIe-Gen5 NVMe; *not*
  the `nvmeprom` ZFS pool). Find it live: `qm list` → the entry with `template`
  set and name containing "Gaming".
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
- **Audio: a VM-level emulated Intel-HDA sink** (`audio0: device=ich9-intel-hda,
  driver=none`) baked into the template. A headless VM's only real audio is the
  GPU's HDMI audio, which is `NOTPRESENT` with no display plugged in → no playback
  endpoint → Apollo logs "no audio". The emulated HDA gives Windows an always-
  active "Speakers" endpoint (built-in HD Audio driver, no software install, host
  backend `none`). Clones inherit it from the template — nothing to do per clone.

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
# the template = template:1 with a "Gaming" name:
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
8. **Hand off:** stream from any already-paired client (Moonlight/Artemis) →
   host `192.168.1.111` (auto-discovers as `Gaming-106`) → **Desktop**. No new
   pairing needed. Only pair (PIN at `apollo.ablz.au`) if it's a brand-new client.

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
- **Audio endpoint:** an ACTIVE "Speakers" render endpoint exists, and the Apollo
  log shows `Selected audio sink` + `Opus initialized` (NOT `Couldn't get default
  audio endpoint` / `no audio`). If missing, confirm `audio0` is in the VM config
  (a stop+start — not a guest reboot — is needed for QEMU to add the device).

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

## Gotchas

- **Two gaming VMs can't run at once** — the GPU is singular. If `qm start`
  errors with the device busy, something else still holds `01:00`; stop it.
- **Don't change a clone's MAC or add pfSense rules.** The shared MAC *is* the
  policy plumbing. A clone with a random MAC won't get `.111` and won't be
  isolated/VPN'd.
- **Linked clones depend on the template.** Don't `qm destroy` the template while
  clones exist. To rebuild the template, that's the de-link/full-clone dance in
  the knowledge doc — out of scope for day-to-day cloning.
- **A clone is only as good as the template.** If you ever rebuild/replace the
  template, re-verify offloads-off + auto-login + pairings + the `audio0` HDA sink
  all survive a reboot before trusting it.
- **RAM:** template is 24 GB (`balloon 0`, passthrough pins it). Don't bump a
  clone's RAM without checking prom headroom — overcommitting a pinned VM can OOM
  the hypervisor (it runs the whole fleet). See Forgejo issue #12.
