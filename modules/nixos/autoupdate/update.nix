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

    updateDates = lib.mkOption {
      type = lib.types.str;
      default = "01:00";
      description = "OnCalendar expression for system.autoUpgrade.";
    };

    collectGarbage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable automatic nix-collect-garbage on a schedule.";
    };

    gcDates = lib.mkOption {
      type = lib.types.str;
      default = "02:00";
      description = "OnCalendar expression for nix.gc automatic GC.";
    };

    trim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable automatic fstrim on a schedule.";
    };

    trimInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "OnCalendar-style interval for fstrim.";
    };

    wakeOnUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Wake the system for the update window.";
    };

    rebootOnKernelUpdate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Reboot if kernel changes.";
    };

    # --- SMART UPDATE GATES ---
    checkWifi = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of allowed SSIDs.";
    };

    minBattery = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Minimum battery percentage required (if not on AC).";
    };

    frequency = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Minimum days elapsed since last successful update.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Base autoUpgrade setup
    system.autoUpgrade = {
      enable = true;
      flake = "github:abl030/nixosconfig#${config.networking.hostName}";
      flags = [
        "--no-write-lock-file"
        "-L"
        "--option"
        "accept-flake-config"
        "true"
      ];
      dates = cfg.updateDates;
      randomizedDelaySec = "60min";
    };

    systemd.timers.nixos-upgrade.timerConfig = {
      WakeSystem = cfg.wakeOnUpdate;
    };

    # 2. Logic Overhaul: Gates + Hibernate Logic
    systemd.services.nixos-upgrade = {
      path = with pkgs; [
        coreutils
        gnugrep
        networkmanager
        gawk
        systemd # for systemctl
      ];

      # We override the script entirely to handle the flow:
      # Check Gates -> (Fail? Hibernate) -> Update -> (Success? Hibernate)
      serviceConfig.ExecStart = lib.mkForce (lib.getExe (pkgs.writeShellScriptBin "smart-nixos-upgrade" ''
        # Logging helper
        log() {
            echo "[SmartUpdate] $1"
        }

        # --- HELPER: Hibernation Safety ---
        # Only hibernate if the lid is CLOSED.
        # This prevents the laptop from sleeping if you are actively using it during the update window.
        function attempt_hibernate() {
           log "Checking post-operation hibernation eligibility..."
           # Check for any closed lid in /proc/acpi
           if grep -q "closed" /proc/acpi/button/lid/*/state 2>/dev/null; then
               log "ACTION: Lid is CLOSED. Initiating system hibernation."
               systemctl hibernate
           else
               log "ACTION: Lid is OPEN (or undetected). Staying awake to avoid user interruption."
           fi
        }

        log "--- STARTING SMART UPDATE SEQUENCE ---"

        # 1. Frequency Gate
        if [ "${toString cfg.frequency}" -gt 0 ]; then
          TIMESTAMP_FILE="/var/lib/nixos-upgrade/last-success-timestamp"
          if [ -f "$TIMESTAMP_FILE" ]; then
            LAST_EPOCH=$(cat "$TIMESTAMP_FILE")
            NOW_EPOCH=$(date +%s)
            MIN_SECONDS=$((${toString cfg.frequency} * 86400))
            DIFF=$((NOW_EPOCH - LAST_EPOCH))
            DAYS=$((DIFF / 86400))

            if [ "$DIFF" -lt "$MIN_SECONDS" ]; then
              log "GATE FAIL: Frequency Check"
              log "  - Last update: $DAYS days ago ($DIFF seconds)"
              log "  - Required: ${toString cfg.frequency} days"
              log "  - Result: SKIPPING update."
              attempt_hibernate
              exit 0
            else
               log "GATE PASS: Frequency Check ($DAYS days elapsed >= ${toString cfg.frequency})"
            fi
          else
            log "GATE PASS: Frequency Check (First run or no timestamp found)"
          fi
        fi

        # 2. SSID Gate
        ALLOWED_SSIDS="${lib.concatStringsSep "|" cfg.checkWifi}"
        if [ -n "$ALLOWED_SSIDS" ]; then
           # Wait a moment for network if we just woke up
           sleep 10
           CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2- || echo "")

           if [ -z "$CURRENT_SSID" ]; then
              log "GATE FAIL: WiFi Check"
              log "  - Current: No connection"
              log "  - Result: SKIPPING update."
              attempt_hibernate
              exit 0
           fi

           if ! echo "$CURRENT_SSID" | grep -qE "^($ALLOWED_SSIDS)$"; then
              log "GATE FAIL: WiFi Check"
              log "  - Current: '$CURRENT_SSID'"
              log "  - Allowed: [$ALLOWED_SSIDS]"
              log "  - Result: SKIPPING update."
              attempt_hibernate
              exit 0
           fi
           log "GATE PASS: WiFi Check (Connected to '$CURRENT_SSID')"
        fi

        # 3. Power Gate
        MIN_BAT=${toString cfg.minBattery}
        ON_AC=0
        for s in /sys/class/power_supply/*; do
          if [ -e "$s/type" ] && [ "$(cat "$s/type")" = "Mains" ]; then
             ONLINE=$(cat "$s/online" 2>/dev/null || echo 0)
             if [ "$ONLINE" -eq 1 ]; then ON_AC=1; break; fi
          fi
        done

        if [ "$ON_AC" -eq 1 ]; then
           log "GATE PASS: Power Check (Connected to AC Mains)"
        elif [ "$MIN_BAT" -gt 0 ]; then
           CAPACITY=0
           for b in /sys/class/power_supply/BAT*; do
              if [ -e "$b/capacity" ]; then
                 c=$(cat "$b/capacity")
                 if [ "$c" -gt "$CAPACITY" ]; then CAPACITY=$c; fi
              fi
           done

           if [ "$CAPACITY" -lt "$MIN_BAT" ]; then
              log "GATE FAIL: Power Check"
              log "  - Source: Battery"
              log "  - Level: $CAPACITY%"
              log "  - Required: $MIN_BAT%"
              log "  - Result: SKIPPING update."
              attempt_hibernate
              exit 0
           else
              log "GATE PASS: Power Check (Battery $CAPACITY% >= $MIN_BAT%)"
           fi
        fi

        log "--- ALL GATES PASSED. EXECUTING NIXOS REBUILD ---"
        log "Target Flake: ${config.system.autoUpgrade.flake}"

        # Run the original nixos-rebuild command
        ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch \
          --flake ${config.system.autoUpgrade.flake} \
          ${lib.concatStringsSep " " config.system.autoUpgrade.flags}

        UPDATE_EXIT_CODE=$?

        if [ $UPDATE_EXIT_CODE -eq 0 ]; then
           log "--- UPDATE SUCCESS ---"
           mkdir -p /var/lib/nixos-upgrade
           date +%s > /var/lib/nixos-upgrade/last-success-timestamp

           # Check Kernel Reboot
           if ${lib.boolToString cfg.rebootOnKernelUpdate}; then
              BOOTED=$(readlink -f /run/booted-system/kernel)
              NEW=$(readlink -f /nix/var/nix/profiles/system/kernel)
              if [ "$BOOTED" != "$NEW" ]; then
                 log "ACTION: Kernel change detected. Rebooting system..."
                 /run/current-system/sw/bin/reboot
                 exit 0 # Reboot takes precedence over hibernate
              fi
           fi
        else
           log "--- UPDATE FAILED (Exit Code $UPDATE_EXIT_CODE) ---"
           log "Check journal above for nixos-rebuild errors."
        fi

        # Cleanup: Go back to sleep if the lid is closed
        attempt_hibernate
      ''));
    };

    # GC and Trim settings remain unchanged
    nix.gc = lib.mkIf cfg.collectGarbage {
      automatic = true;
      dates = cfg.gcDates;
      options = "--delete-older-than 3d";
    };

    services.fstrim = lib.mkIf cfg.trim {
      enable = true;
      interval = cfg.trimInterval;
    };
  };
}
