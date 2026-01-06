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
      description = "Wake the system (from Suspend) for the update window.";
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
      description = "List of allowed SSIDs. If empty, allows any connection.";
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

    # Ensure the timer wakes the system
    systemd.timers.nixos-upgrade.timerConfig = {
      WakeSystem = cfg.wakeOnUpdate;
    };

    # 2. Logic Overhaul: Wifi Gate -> Update
    systemd.services.nixos-upgrade = {
      path = with pkgs; [
        coreutils
        gnugrep
        networkmanager
        gawk
        systemd # for systemctl reboot
      ];

      # We override the script to handle Gates and Kernel checks
      serviceConfig.ExecStart = lib.mkForce (lib.getExe (pkgs.writeShellScriptBin "smart-nixos-upgrade" ''
        # Logging helper
        log() {
            echo "[SmartUpdate] $1"
        }

        log "--- STARTING SMART UPDATE SEQUENCE ---"

        # 1. SSID Gate
        ALLOWED_SSIDS="${lib.concatStringsSep "|" cfg.checkWifi}"
        if [ -n "$ALLOWED_SSIDS" ]; then
           log "Checking Network..."

           # WAIT LOOP: Wait up to 45 seconds for NetworkManager to settle
           # This solves the issue where the check runs before Wifi re-associates after wake.
           for i in {1..45}; do
               STATE=$(nmcli -t -f state general 2>/dev/null || echo "unknown")
               if [[ "$STATE" == "connected" ]]; then
                   break
               fi
               if [ "$i" -eq 1 ]; then log "Waiting for connection (max 45s)..."; fi
               sleep 1
           done

           CURRENT_SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2- || echo "")

           if [ -z "$CURRENT_SSID" ]; then
              log "GATE FAIL: WiFi Check"
              log "  - Current: No connection (or timed out)"
              log "  - Result: SKIPPING update."
              exit 0
           fi

           if ! echo "$CURRENT_SSID" | grep -qE "^($ALLOWED_SSIDS)$"; then
              log "GATE FAIL: WiFi Check"
              log "  - Current: '$CURRENT_SSID'"
              log "  - Allowed: [$ALLOWED_SSIDS]"
              log "  - Result: SKIPPING update."
              exit 0
           fi
           log "GATE PASS: WiFi Check (Connected to '$CURRENT_SSID')"
        fi

        log "--- GATES PASSED. EXECUTING NIXOS REBUILD ---"
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
                 exit 0
              fi
           fi
        else
           log "--- UPDATE FAILED (Exit Code $UPDATE_EXIT_CODE) ---"
           log "Check journal above for nixos-rebuild errors."
        fi
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
