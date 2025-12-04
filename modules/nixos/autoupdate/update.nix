{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.homelab.update;
in {
  options.homelab.update = {
    enable = lib.mkEnableOption "Nightly flake switch & housekeeping (via system.autoUpgrade + timers)";

    collectGarbage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable automatic nix-collect-garbage on a schedule.";
    };

    gcDates = lib.mkOption {
      type = lib.types.str;
      default = "02:00";
      example = "daily";
      description = ''
        OnCalendar expression for nix.gc automatic GC.
        Examples:
          "daily"          – run once per day
          "02:00"          – run every day at 02:00
          "Sun 03:00"      – weekly on Sundays at 03:00
      '';
    };

    trim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable automatic fstrim on a schedule.";
    };

    trimInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      example = "weekly";
      description = ''
        OnCalendar-style interval for fstrim.
        Common values: "daily", "weekly", or e.g. "Mon *-*-* 03:00:00".
      '';
    };

    # New option: Wake from sleep/s2idle
    wakeOnUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to configure the systemd timer to wake the system from sleep
        (e.g. s2idle) to perform the update.
      '';
    };

    # New option: Reboot on kernel change
    rebootOnKernelUpdate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If enabled, the system will automatically reboot after a successful update
        ONLY if the kernel version (store path) has changed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    #### 1. Flake-based auto-upgrade using official machinery ####
    #
    # This uses nixos-upgrade.service/timer instead of our own
    # switch-to-configuration wrapper, avoiding the “service kills itself
    # mid-switch” problem.
    #
    system.autoUpgrade = {
      enable = true;

      # Use your GitHub flake and select the host by hostname.
      flake = "github:abl030/nixosconfig#${config.networking.hostName}";

      # Don't try to write flake.lock back to the remote; accept flake config.
      flags = [
        "--no-write-lock-file"
        "-L"
        "--option"
        "accept-flake-config"
        "true"
      ];

      # Run once a day around 01:00, with up to 60min jitter.
      dates = "01:00";
      randomizedDelaySec = "60min";
    };

    #
    # NEW LOGIC: Wake from sleep
    #
    systemd.timers.nixos-upgrade.timerConfig = {
      # If true, sets an RTC alarm to wake the system for the update window.
      WakeSystem = cfg.wakeOnUpdate;
    };

    #
    # NEW LOGIC: Conditional Kernel Reboot
    #
    # We append an ExecStartPost script to the official nixos-upgrade service.
    # This script runs only if the update (ExecStart) succeeded.
    # It compares the booted kernel against the new system kernel.
    #
    systemd.services.nixos-upgrade.serviceConfig.ExecStartPost = lib.mkIf cfg.rebootOnKernelUpdate [
      (lib.getExe (pkgs.writeShellScriptBin "post-update-kernel-check" ''
        # Resolve the paths to the kernels
        BOOTED_KERNEL=$(readlink -f /run/booted-system/kernel)
        NEW_KERNEL=$(readlink -f /nix/var/nix/profiles/system/kernel)

        if [ "$BOOTED_KERNEL" != "$NEW_KERNEL" ]; then
          echo "[AutoUpdate] Kernel change detected:"
          echo "  Old: $BOOTED_KERNEL"
          echo "  New: $NEW_KERNEL"
          echo "[AutoUpdate] Scheduling reboot in 1 minute..."
          ${pkgs.systemd}/bin/shutdown -r +1 "Auto-update installed a new kernel. Rebooting..."
        else
          echo "[AutoUpdate] No kernel change detected. Skipping reboot."
        fi
      ''))
    ];

    #### 2. Daily GC ####
    nix.gc = lib.mkIf cfg.collectGarbage {
      automatic = true;
      # Daily (or whatever cfg.gcDates is set to).
      dates = cfg.gcDates;
      # Keep some history so you can still roll back.
      options = "--delete-older-than 3d";
    };

    #### 3. Daily TRIM ####
    services.fstrim = lib.mkIf cfg.trim {
      enable = true;
      # Systemd OnCalendar expression – "daily" by default.
      interval = cfg.trimInterval;
    };
  };
}
# ---------------------------------------------------------------------------
# Usage notes / examples
#
# 1. Standard Server/Desktop:
#    Enable updates, wake from sleep if necessary, and reboot if the kernel changes.
#
#   homelab.update = {
#     enable = true;
#     rebootOnKernelUpdate = true;
#     # wakeOnUpdate = true; # default
#   };
#
# 2. Laptop (Power saving):
#    Enable updates, but DO NOT wake the system from sleep (prevents heating up
#    in a backpack). Only updates when the machine is already on.
#
#   homelab.update = {
#     enable = true;
#     wakeOnUpdate = false;
#   };
#
# 3. WSL / Container:
#    GC daily, no TRIM (often unsupported), no wake (handled by host/Windows),
#    and usually no reboot logic needed.
#
#   homelab.update = {
#     enable = true;
#     collectGarbage = true;
#     gcDates = "daily";
#     trim = false;
#     wakeOnUpdate = false;
#   };
#
# Checking logs for auto-upgrade activity:
#
#   journalctl -u nixos-upgrade.service -u nixos-upgrade.timer -f
#
# (Drop the -f if you just want historical logs instead of live tail.)
# ---------------------------------------------------------------------------

