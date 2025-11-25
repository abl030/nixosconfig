{
  lib,
  config,
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
# Example host config for WSL where we want GC daily but no TRIM:
#
#   # hosts/wsl/configuration.nix
#   homelab.update = {
#     enable = true;
#     collectGarbage = true;
#     gcDates = "daily";
#     trim = false;   # disable TRIM on WSL specifically
#   };
#
# Checking logs for auto-upgrade activity:
#
#   journalctl -u nixos-upgrade.service -u nixos-upgrade.timer -f
#
# (Drop the -f if you just want historical logs instead of live tail.)
# ---------------------------------------------------------------------------

