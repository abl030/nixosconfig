# SSH into the WSL VM over Tailscale (Windows portproxy bridge)

**Date:** 2026-06-06 · **Status:** working, dual entrypoints verified 2026-08-20; self-healing task verified 2026-09-29 · **Host:** `wsl` (distro `NixOS` on `laptop-btibh4ie`)

## Problem

We want to `ssh nixos@<laptop>` into the WSL VM from the tailnet. But:

- **Tailscale is NOT run inside WSL** (`homelab.tailscale.enable = false` in
  `hosts/wsl/configuration.nix`). Running a second `tailscaled` inside WSL fought
  with the Windows host's Tailscale over routing and broke connectivity. The WSL
  VM instead reaches the LAN (e.g. NFS `192.168.1.2`) via the **Windows host's
  Tailscale subnet route** — see [`nfs-over-tailscale.md`](nfs-over-tailscale.md).
- WSL2 runs behind NAT on the Windows host. `eth0` is a private NAT address
  (e.g. `172.26.235.3/20`) that changes on every reboot / `wsl --shutdown`.
- Tailscale lives on the **Windows** host (`laptop-btibh4ie`, `100.75.246.114`),
  not in the VM.

`sshd` inside WSL already listens on `0.0.0.0:22` (`homelab.ssh.enable = true`,
keys from `hosts.nix`). The only gap is getting tailnet traffic to it.

## Solution: `netsh portproxy` on the Windows host, self-healing task

A Windows scheduled task runs `Update-WslPortproxy.ps1` at startup, at logon and
every 15 minutes. The script:

1. Discovers the current WSL `eth0` IP (eth0 only — `hostname -I` would also
   return the docker bridge IPs `172.17/172.18`). Waits up to 5 min.
2. Discovers the Windows Tailscale IP from the `Tailscale` network adapter
   (`Get-NetIPAddress`, not `tailscale.exe`). Waits up to 10 min.
3. Ensures **`<tailscaleIP>:22 → <wslIP>:22`**, binding the listener to the
   Tailscale IP *only* (so it never appears on the LAN or public interfaces).
   It then **checks that a listener actually exists** on that address and port,
   and deletes and re-adds the rule until one does (up to 5 tries).
4. Does the same for the pre-existing `0.0.0.0:443 → <wslIP>:443` forward.
5. Ensures an inbound firewall allow: TCP 22, LocalAddress = Tailscale IP,
   RemoteAddress = `100.64.0.0/10` (tailnet CGNAT range). Defense in depth.

When everything is already correct the run is a no-op, so the 15-minute
repetition never disturbs a working forward. Each run appends one line to
`last-run.log` next to the script (trimmed to about 200 lines).

### Incident 2026-09-23 → 29: rule present, nothing listening

`ssh wsl` timed out for six days after a Windows reboot, although
`netsh interface portproxy show v4tov4` still listed
`100.75.246.114:22 → <wslIP>:22` with the correct WSL IP.

- IP Helper (`iphlpsvc`) binds a portproxy listener **once**. At boot the
  Tailscale address did not exist yet, so the bind to `100.75.246.114:22` failed
  and was never retried. Only `127.0.0.1:22` (WSL's own localhost relay) was
  listening; the `0.0.0.0:443` forward was unaffected.
- The old logon-only task waited just 60 s for `tailscale.exe ip -4`, gave up
  (`LastTaskResult = 1`), and exited before re-adding the rule. Re-adding would
  have forced a fresh bind.
- **Diagnose:** `netstat -ano -p tcp | findstr LISTENING | findstr ":22 "` must
  show `100.75.246.114:22` (owned by the IP Helper svchost). A rule without a
  listener is this failure.
- **Fix:** the listener check, longer waits, and startup plus 15-minute triggers
  described above. Verified by deleting the `:22` rule and running the task,
  which logged `fixing forward … listening=False` and restored `ssh wsl`.

### Locations (Windows side, NOT in this repo)

- Script: `C:\Users\abl030\wsl-portproxy\Update-WslPortproxy.ps1` (the
  pre-2026-09-29 version is kept as `Update-WslPortproxy.ps1.bak`)
- Task registration: `C:\Users\abl030\wsl-portproxy\Register-PortproxyTask.ps1`;
  the previous task definition is exported as `task-backup.xml` there.
- Scheduled task: `WSL-Tailscale-Portproxy` — runs as user `abl030` with
  **S4U** logon ("run whether logged on or not", no stored password) and
  **highest privileges**. Triggers: **at startup** (1 min delay), **at logon**,
  and **every 15 minutes**. `IgnoreNew` for overlapping runs, 20-minute limit.
- Rollback: `Register-ScheduledTask -TaskName WSL-Tailscale-Portproxy -Xml (Get-Content task-backup.xml -Raw) -Force`
  and restore the `.bak` script.

### Why run as the user (not SYSTEM)

SYSTEM cannot see a per-user WSL distro, so `wsl.exe -d NixOS` fails as SYSTEM.
The task runs as `abl030`; "highest privileges" lets it run `netsh` / firewall
cmdlets silently (the account is a local admin), no UAC prompt. S4U works for
`wsl.exe`: the `Start-NixOS-WSL` boot task uses the same logon type. S4U has
no network credentials, which doesn't matter here (see
[`wsl-ondemand-data-mount.md`](wsl-ondemand-data-mount.md) for where it does).

## Two intentional tailnet SSH entrypoints

The Windows host owns the one Tailscale identity, but the WSL and Windows
administration surfaces are deliberately separate:

| Command | Destination | Transport |
|---|---|---|
| `ssh wsl` | NixOS WSL (`nixos`) | `laptop-btibh4ie:22` portproxy → WSL `:22` |
| `ssh wsl-laptop` | Windows (`LAPTOP-BTIBH4IE\\abl030`) | Windows OpenSSH at `laptop-btibh4ie:2222` |

`:22` remains owned by the `WSL-Tailscale-Portproxy` task. Windows OpenSSH
instead has `Port 2222` and `ListenAddress 100.75.246.114` in
`C:\ProgramData\ssh\sshd_config`; it is delayed-automatic and depends on the
Windows `Tailscale` service. Its firewall rule permits TCP 2222 only when the
local address is the Tailscale address and the remote address is in
`100.64.0.0/10`. It must not listen on a LAN or public address.

The aliases and the Windows `:2222` host key pin are generated for the fleet by
`modules/home-manager/services/ssh.nix` and
`modules/nixos/services/ssh/default.nix`. Tailnet policy permits Windows `:2222`
only from `doc1`; the existing WSL `:22` grant remains available to `doc1` and
`framework`. See
[`windows-fleet-ssh-access.md`](windows-fleet-ssh-access.md) for the generic
fleet-key installation procedure.

## Verify

```powershell
netsh interface portproxy show v4tov4          # expect 100.75.246.114:22 -> <wslIP>:22
Get-ScheduledTaskInfo -TaskName 'WSL-Tailscale-Portproxy'   # LastTaskResult = 0
```

From a fleet host:

```bash
ssh wsl          # NixOS WSL
ssh wsl-laptop   # Windows host
```

The expected listening boundary is `100.75.246.114:22` for the WSL portproxy
and `100.75.246.114:2222` for Windows OpenSSH; neither Windows SSH endpoint may
be reachable on the laptop's LAN addresses.

## Limitations / footguns

- A cold reboot with nobody logged in is covered: `Start-NixOS-WSL` boots the
  VM at startup, and this task runs at startup too (S4U).
- `wsl --shutdown` mid-session changes the WSL IP. The forward heals within 15
  minutes; to fix it immediately, run
  `Start-ScheduledTask -TaskName 'WSL-Tailscale-Portproxy'` (or
  `schtasks /run /tn WSL-Tailscale-Portproxy` over `ssh wsl-laptop`).
- **Not** WSL "mirrored" networking mode: cleaner conceptually but bigger blast
  radius (collides with docker bridges, can disturb the working NFS subnet route).
  Portproxy is surgical and matches the existing 443 forward pattern on this box.
