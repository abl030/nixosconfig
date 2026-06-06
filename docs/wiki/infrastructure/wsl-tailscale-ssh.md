# SSH into the WSL VM over Tailscale (Windows portproxy bridge)

**Date:** 2026-06-06 · **Status:** working · **Host:** `wsl` (distro `NixOS` on `laptop-btibh4ie`)

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

## Solution: `netsh portproxy` on the Windows host, refreshed each logon

A Windows scheduled task runs `Update-WslPortproxy.ps1` at logon. The script:

1. Discovers the current WSL `eth0` IP (eth0 only — `hostname -I` would also
   return the docker bridge IPs `172.17/172.18`).
2. Discovers the Windows Tailscale IP (`tailscale.exe ip -4`).
3. Forwards **`<tailscaleIP>:22 → <wslIP>:22`**, binding the listener to the
   Tailscale IP *only* (so it never appears on the LAN or public interfaces).
4. Re-points the pre-existing `0.0.0.0:443 → <wslIP>:443` forward to the live
   WSL IP (it had the IP hardcoded and would break on reboot).
5. Ensures an inbound firewall allow: TCP 22, LocalAddress = Tailscale IP,
   RemoteAddress = `100.64.0.0/10` (tailnet CGNAT range). Defense in depth.

### Locations (Windows side, NOT in this repo)

- Script: `C:\Users\abl030\wsl-portproxy\Update-WslPortproxy.ps1`
- Scheduled task: `WSL-Tailscale-Portproxy` — runs as user `abl030`,
  trigger **At logon**, **Run with highest privileges**.

### Why run as the user (not SYSTEM)

SYSTEM cannot see a per-user WSL distro, so `wsl.exe -d NixOS` fails as SYSTEM.
The task runs as `abl030`; "highest privileges" lets it run `netsh` / firewall
cmdlets silently (the account is a local admin), no UAC prompt.

## Verify

```powershell
netsh interface portproxy show v4tov4          # expect 100.75.246.114:22 -> <wslIP>:22
Get-ScheduledTaskInfo -TaskName 'WSL-Tailscale-Portproxy'   # LastTaskResult = 0
```

From another tailnet device: `ssh nixos@100.75.246.114` (or by MagicDNS name).

## Limitations / footguns

- **Trigger is "at logon."** After a cold reboot with nobody logged into Windows,
  WSL won't start and SSH is unreachable until someone logs in. Acceptable for a
  laptop. For true headless, switch the task to "run whether logged on or not"
  with stored creds (finicky with WSL profile loading, but doable).
- `wsl --shutdown` mid-session changes the WSL IP and the forward goes stale until
  next logon. Re-run: `Start-ScheduledTask -TaskName 'WSL-Tailscale-Portproxy'`.
- **Not** WSL "mirrored" networking mode: cleaner conceptually but bigger blast
  radius (collides with docker bridges, can disturb the working NFS subnet route).
  Portproxy is surgical and matches the existing 443 forward pattern on this box.
