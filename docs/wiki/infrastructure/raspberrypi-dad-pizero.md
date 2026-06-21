# Dad's Raspberry Pi (Pi Zero W) — access + the bookworm upgrade (IN PROGRESS)

- **Date:** 2026-06-21
- **Status:** ⚠️ **MID-UPGRADE, currently OFF the tailnet.** An in-place Raspbian
  **bullseye → bookworm** upgrade is running; the box dropped off the tailnet at
  `07:18 UTC` (right after tailscaled restarted into 1.98.4) — almost certainly
  OOM/thrash on the 427 MB box killed tailscaled. Waiting for self-recovery or a
  dad-side power-cycle. **Resume steps below.**

## What it is

- **Hardware:** Raspberry Pi **Zero W Rev 1.1** — `armv6l`/`armhf`, **427 MB RAM**,
  single core, 7.1 GB SD (~4 GB free). Underpowered.
- **OS (pre-upgrade):** Raspbian (Raspberry Pi OS) **bullseye 11.11**, kernel
  `6.12.25+` (rpi-update'd). Upgrading toward Debian 12 (bookworm); trixie is a
  later second hop.
- **Location:** dad's house — **remote, wifi-only**. We reach it **only over
  Tailscale** (no LAN, no console from our side). Physical recovery = dad.
- **Role:** Tailscale **subnet router** advertising **`192.168.2.0/24`** (dad's
  LAN) + offers an exit node. Historically a Pi-hole ("pihole" hostname/keys) but
  pihole-FTL is **not** currently running; only `tailscaled` is a notable service.
- **Tailnet identity:** node `raspberrypi`, **`tag:edge`**, IP `100.88.30.54`,
  device id `811692744053917`.

## Access model (set up 2026-06-21)

- **ACL (#239):** `doc1 → rpi : tcp:22` grant (commit `928990f2`) — the bastion can
  SSH the pi. `tag:client → 192.168.2.0/24` gives clients dad's-LAN access via the
  route; `autoApprovers: 192.168.2.0/24 → tag:edge`. Under default-deny, **servers
  other than doc1, and the pi's own node IP from clients, are NOT reachable** — by
  design. (Why it vanished from `tailscale status` on doc1 before the grant:
  default-deny netmap pruning. See [tailscale-acl](tailscale-acl.md).)
- **SSH login:** **key-only** — doc1's `~/.ssh/id_ed25519.pub`
  (`...DGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity`) is in
  `pi@raspberrypi:~/.ssh/authorized_keys`. So `ssh pi@raspberrypi` from doc1 works
  passwordless. The `pi` user has **passwordless sudo**.
- **Breakglass:** SSH password auth was disabled (`/etc/ssh/sshd_config.d/99-disable-password.conf`),
  then **RE-ENABLED for the upgrade** (same file → `PasswordAuthentication yes`) so
  dad can log in at the console with the password if the upgrade breaks networking.
  **Re-tighten to `no` + `systemctl reload ssh` once the upgrade is confirmed good.**
- **Note (git history):** the old `root@pihole` key dropped in #270 was the **pi→fleet**
  trust (pi SSHing *into* fleet hosts), not login-into-pi. Don't re-chase it for SSH-in.

## The bookworm upgrade (how it was launched)

- Started ~`06:21 UTC` 2026-06-21, driven from doc1 over SSH.
- **Detached in tmux** so it survives disconnects: session `upgrade`, script
  `~/upgrade-bookworm.sh`, log `~/upgrade-bookworm.log`, completion marker
  `~/upgrade-bookworm.DONE`. **The script deliberately does NOT reboot** — it stops
  after `apt full-upgrade` + verification so we can inspect the network-stack
  migration before the risky reboot.
- Method: `sed bullseye→bookworm` across `/etc/apt/sources.list` +
  `sources.list.d/*.list` (tailscale's `bookworm/raspbian` repo **does** exist);
  `apt-get update` (aborts if sources bad); `apt-get upgrade --without-new-pkgs`
  then `full-upgrade` with `-o Dpkg::Options::=--force-confold` (keep existing
  configs, incl. our sshd drop-in + authorized_keys).

### Gotchas hit
- **`DEBIAN_FRONTEND=noninteractive` does NOT survive `sudo`** (env_reset) → a
  debconf dialog appeared (libc6 "restart services without asking?"). Answered
  **Yes** via `tmux send-keys -t upgrade Left Enter`. Same reason `NEEDRESTART_MODE=a`
  didn't take. **Next time: `sudo -E` or `sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get …`.**
- **427 MB is too small for an in-place release upgrade.** The configure phase
  blew through RAM; tailscaled (our only access path) got OOM-killed / starved →
  box went dark on the tailnet at `07:18 UTC`.

## RESUME HERE (next session)

1. **Is it back?**
   ```sh
   tailscale ping 100.88.30.54                 # from doc1
   ssh pi@raspberrypi 'cat /etc/os-release | grep PRETTY; ls ~/upgrade-bookworm.DONE 2>/dev/null && echo DONE || echo running; tail -n 30 ~/upgrade-bookworm.log'
   ```
   - **Off-tailnet for a long time?** → dad power-cycles it. RISK: a power pull
     mid-`dpkg --configure` = broken package state. After it boots, run
     `sudo dpkg --configure -a` and `sudo apt-get -f install` to finish.
2. **If `DONE` and it's reachable — verify BEFORE rebooting:**
   - sshd: `sudo sshd -T | grep -iE '^(passwordauthentication|pubkeyauthentication)'` (want pubkey yes; password yes = breakglass still on for the reboot).
   - **network stack (the real reboot risk):** bookworm prefers **NetworkManager**;
     this is a **wifi-only** box, so confirm wifi will come up post-reboot —
     `systemctl is-enabled NetworkManager dhcpcd; ls /etc/NetworkManager/system-connections/ 2>/dev/null; cat /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null`.
     If only the old `dhcpcd`/`wpa_supplicant` config exists and NM is now active,
     **pre-create an NM wifi connection from the SSID/PSK** before rebooting, or it
     drops off (→ dad console).
3. **Reboot (moment of truth):** `sudo reboot`, then from doc1 poll
   `tailscale ping 100.88.30.54` / `ssh pi@raspberrypi`. Expect 1–3 min.
4. **If healthy:** re-tighten SSH (set the drop-in back to `PasswordAuthentication no`,
   `sudo systemctl reload ssh`), confirm tailscale routes still approved
   (`192.168.2.0/24` + exit), update this doc's status, and consider the
   bookworm→trixie hop (or stop here).

## Recommendation for "do it properly"

In-place release upgrades on a Pi Zero W are fragile (OOM + the dhcpcd→NM wifi
landmine + remote lockout). The Raspberry Pi Foundation recommends **reflashing**
for major version jumps. **Best path: when physically at dad's, reflash current
Raspberry Pi OS and re-provision** — `tailscale up --advertise-routes=192.168.2.0/24
--advertise-exit-node`, re-add doc1's key to `authorized_keys`, disable SSH
password auth, pihole if wanted. Avoids every landmine above. (Staying on patched
bullseye LTS until ~Aug 2026 was also a perfectly fine option.)

## Related
- [tailscale-acl](tailscale-acl.md) — the default-deny model + the `doc1→rpi` grant.
- #239 (tailscale least-privilege ACL). Pi's route + exit are part of `tag:edge`.
