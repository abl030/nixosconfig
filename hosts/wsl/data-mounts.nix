# forgejo#4: On-demand, self-unmounting access to the home NAS from wsl.
#
# wsl is the fleet's presence at the Cullen site (tag:cullen, #239) and the
# least-trusted box in the fleet. The shared NFS module
# (modules/nixos/services/mounts/nfs.nix) mounts the WHOLE tower data share RW
# via `x-systemd.automount` — i.e. *any* filesystem access (an indexer, a
# `find /`, a ransomware crawler) silently mounts it, and the 5-min idle-timeout
# never fires while an encryptor keeps touching it. The tower `data` share is
# NOT on ZFS, so there is no fast server-side rollback if it gets encrypted.
#
# So on wsl we DON'T use the shared automount (`homelab.mounts.nfs.enable =
# false` in configuration.nix). Instead:
#   * The whole share is mounted ONLY when the human runs `data-mount`, and is
#     auto-unmounted after 15 min idle + force-unmounted nightly at 02:00 — so
#     it is invisible/unmounted the ~23h/day it isn't in use, defeating
#     commodity overnight ransomware that crawls already-mounted drives.
#   * The unattended nightly writer (ops-sync) gets its OWN narrow just-in-time
#     mount scoped to the Cullen backup folder — see
#     modules/nixos/services/mounts/ops-sync.nix.
#
# This is a window-limiter, not a blast-radius bound: while you're logged in and
# working with it mounted RW, everything is reachable by anything running as you
# (recovery for that worst case is the offsite kopia backups, since the NAS
# can't snapshot). Full rationale: forgejo#4.
{
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  mountPoint = "/mnt/data";
  # wsl reaches tower over the Windows host's Tailscale subnet route.
  remote = "192.168.1.2:/mnt/user/data";
  # Stable path so the sudoers rule and the wrapper commands agree on the exact
  # command string (sudoers matches by absolute path). This path does not change
  # across rebuilds, unlike a ${pkgs.systemd} store path.
  systemctl = "/run/current-system/sw/bin/systemctl";
  mountUnit = "mnt-data.mount";
  idleState = "/run/data-mount-idle-since";
  idleGrace = 900; # 15 minutes with no open files -> unmount

  data-mount = pkgs.writeShellApplication {
    name = "data-mount";
    runtimeInputs = [pkgs.util-linux];
    text = ''
      if mountpoint -q ${mountPoint}; then
        echo "${mountPoint} already mounted."
        exit 0
      fi
      echo "Mounting home NAS (${remote}) -> ${mountPoint} (read-write)..."
      sudo -n ${systemctl} start ${mountUnit}
      echo "Mounted. Auto-unmounts after 15 min idle; force-unmounted nightly at 02:00."
      echo "Unmount now with: data-umount"
    '';
  };

  data-umount = pkgs.writeShellApplication {
    name = "data-umount";
    runtimeInputs = [pkgs.util-linux];
    text = ''
      if ! mountpoint -q ${mountPoint}; then
        echo "${mountPoint} is not mounted."
        exit 0
      fi
      if sudo -n ${systemctl} stop ${mountUnit}; then
        echo "Unmounted ${mountPoint}."
      else
        echo "Failed to unmount — something is using it. cd out of ${mountPoint} and close open files, then retry." >&2
        exit 1
      fi
    '';
  };
in {
  # Manual, RW mount of the whole home NAS share. `noauto` and NO
  # x-systemd.automount: it is NEVER mounted on access, only by `data-mount`
  # (which starts this generated mnt-data.mount unit via the narrow sudo rule
  # below). `soft`/timeo/retrans so a dead tailnet path can't pin the kernel.
  fileSystems.${mountPoint} = {
    device = remote;
    fsType = "nfs";
    options = [
      "noauto"
      "_netdev"
      "noatime"
      "nfsvers=4.2"
      "soft"
      "timeo=30"
      "retrans=2"
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
    ];
  };

  environment.systemPackages = [pkgs.nfs-utils data-mount data-umount];

  # Least-privilege trigger: wsl is locked (no passwordless sudo; `nixos` has no
  # password), so the user can't `sudo mount`. Grant NOPASSWD for EXACTLY
  # start/stop of the one mount unit and nothing else. mkAfter so it renders
  # last and wins (sudoers is last-match). Mirrors the igpu narrow-sudo pattern.
  security.sudo.extraRules = lib.mkAfter [
    {
      users = [hostConfig.user];
      commands = [
        {
          command = "${systemctl} start ${mountUnit}";
          options = ["NOPASSWD"];
        }
        {
          command = "${systemctl} stop ${mountUnit}";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  # Idle reaper: every 5 min, if /mnt/data is mounted but nothing has files open
  # under it for `idleGrace`, unmount it. `fuser -sm` holds the mount while a
  # shell is cd'd into it or a file is open, so this only reaps genuinely-idle
  # mounts; re-mounting is one `data-mount` away.
  systemd.services.data-mount-reaper = {
    description = "Unmount /mnt/data after it has been idle (no open files)";
    path = [pkgs.util-linux pkgs.psmisc pkgs.coreutils];
    serviceConfig.Type = "oneshot";
    script = ''
      set -uo pipefail
      MP=${mountPoint}
      STATE=${idleState}
      GRACE=${toString idleGrace}

      if ! mountpoint -q "$MP"; then
        rm -f "$STATE"
        exit 0
      fi

      if fuser -sm "$MP" 2>/dev/null; then
        # Active use -> reset the idle clock.
        rm -f "$STATE"
        exit 0
      fi

      now=$(date +%s)
      if [ ! -f "$STATE" ]; then
        echo "$now" > "$STATE"
        exit 0
      fi

      since=$(cat "$STATE" 2>/dev/null || echo "$now")
      if [ $(( now - since )) -ge "$GRACE" ]; then
        if umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null; then
          logger -t data-mount-reaper "unmounted $MP after ''${GRACE}s idle"
        fi
        rm -f "$STATE"
      fi
    '';
  };

  systemd.timers.data-mount-reaper = {
    description = "Periodic idle check for the on-demand /mnt/data mount";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };

  # Backstop: guarantee /mnt/data is DOWN overnight (the ransomware window),
  # even if a shell is parked in it so the idle reaper won't fire. Force + lazy
  # so a busy mount still comes down.
  systemd.services.data-mount-nightly-umount = {
    description = "Force-unmount /mnt/data overnight so the home NAS is never left mounted unattended";
    path = [pkgs.util-linux pkgs.coreutils];
    serviceConfig.Type = "oneshot";
    script = ''
      set -uo pipefail
      MP=${mountPoint}
      if mountpoint -q "$MP"; then
        umount -l -f "$MP" 2>/dev/null || true
        rm -f ${idleState}
        logger -t data-mount-reaper "nightly forced unmount of $MP"
      fi
    '';
  };

  systemd.timers.data-mount-nightly-umount = {
    description = "Nightly forced unmount of /mnt/data";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;
    };
  };
}
