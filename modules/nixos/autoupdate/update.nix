{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.update;

  # Worker does: build (from remote flake) → switch → GC → TRIM
  workerScript = pkgs.writeShellScript "homelab-auto-update-worker.sh" ''
    set -euo pipefail
    umask 077

    # Build from REMOTE by default; override with NIXOS_AUTO_UPDATE_FLAKE if needed.
    flake="''${NIXOS_AUTO_UPDATE_FLAKE:-https://github.com/abl030/nixosconfig}"

    # Host to build; override with NIXOS_AUTO_UPDATE_HOST if you like.
    host="''${NIXOS_AUTO_UPDATE_HOST:-$(${pkgs.inetutils}/bin/hostname)}"
    attr="nixosConfigurations.''${host}.config.system.build.toplevel"

    echo "[homelab-auto-update] Building toplevel for host ''${host} from ''${flake}"
    out="$(${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' \
      build --no-link --print-out-paths "''${flake}#''${attr}")"

    echo "[homelab-auto-update] Switching to: $out"
    NIXOS_INSTALL_BOOTLOADER=1 "$out/bin/switch-to-configuration" switch

    ${lib.optionalString cfg.collectGarbage ''
      echo "[homelab-auto-update] Collecting old generations…"
      ${pkgs.nix}/bin/nix-collect-garbage -d
    ''}

    ${lib.optionalString cfg.trim ''
      echo "[homelab-auto-update] TRIM via system fstrim.service…"
      /run/current-system/systemd/bin/systemctl start --wait fstrim.service || true
    ''}

    echo "[homelab-auto-update] Done."
  '';

  # Launcher spawns the worker in its own transient unit and exits quickly.
  launcherScript = pkgs.writeShellScript "homelab-auto-update-launcher.sh" ''
    set -euo pipefail
    unit="homelab-auto-update-worker-$(${pkgs.coreutils}/bin/date +%s)-$$"
    echo "[homelab-auto-update] Spawning transient unit: ''${unit}"
    /run/current-system/systemd/bin/systemd-run \
      --collect \
      --property=Type=exec \
      --property=Description="Homelab auto-update worker" \
      --unit="''${unit}" \
      "${workerScript}"
    echo "[homelab-auto-update] Launched ''${unit}; exiting launcher."
  '';
in {
  options.homelab.update = {
    enable = lib.mkEnableOption "Nightly flake switch with jittered schedule";

    collectGarbage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run nix-collect-garbage -d after successful switch.";
    };

    trim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run TRIM after successful switch (uses system fstrim.service).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.fstrim.enable = true;

    # New, collision-free unit name
    systemd.services.homelab-auto-update = {
      description = "Homelab nightly flake switch";
      wants = ["network-online.target"];
      after = ["network-online.target"];

      # Clean, unsandboxed launcher
      serviceConfig = lib.mkForce {
        Type = "oneshot";
        ExecStart = launcherScript;

        StateDirectory = "nixos-auto-update"; # /var/lib/nixos-auto-update
        CacheDirectory = "nixos-auto-update"; # /var/cache/nixos-auto-update
        WorkingDirectory = "/var/lib/nixos-auto-update";
        Environment = [
          # Default to REMOTE flake; override at start time if needed:
          #   sudo env NIXOS_AUTO_UPDATE_FLAKE=/home/abl030/nixosconfig systemctl start homelab-auto-update
          "NIXOS_AUTO_UPDATE_FLAKE=https://github.com/abl030/nixosconfig"
          "HOME=/var/lib/nixos-auto-update"
          "XDG_CONFIG_HOME=/var/lib/nixos-auto-update"
          "XDG_CACHE_HOME=/var/cache/nixos-auto-update"
          "GIT_TERMINAL_PROMPT=0"
        ];

        TimeoutStartSec = "5m"; # launcher returns quickly
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.timers.homelab-auto-update = {
      description = "Run homelab-auto-update between 01:00–02:00 with jitter";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 01:00:00";
        RandomizedDelaySec = "60m";
        AccuracySec = "1m";
        Persistent = true;
      };
    };

    # Make sure the old unit names stay off
    systemd.services.nixos-auto-update.enable = lib.mkForce false;
    systemd.timers.nixos-auto-update.enable = lib.mkForce false;
  };
}
