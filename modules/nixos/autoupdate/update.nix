{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.update;

  updaterScript = pkgs.writeShellScript "nixos-auto-update.sh" ''
    set -euo pipefail
    umask 077

    workdir="$(${pkgs.coreutils}/bin/mktemp -d -t nixos-auto-update.XXXXXX)"
    cleanup() {
      if [ -n "''${workdir-}" ] && [ -d "$workdir" ]; then
        ${pkgs.coreutils}/bin/chmod -R u+rwX "$workdir" 2>/dev/null || true
        ${pkgs.coreutils}/bin/rm -rf --one-file-system "$workdir" || true
      fi
    }
    trap cleanup EXIT INT TERM HUP

    echo "[nixos-auto-update] Using temp dir: $workdir"
    echo "[nixos-auto-update] Cloning flake…"
    ${pkgs.git}/bin/git clone --depth 1 https://github.com/abl030/nixosconfig "$workdir/nixosconfig"

    host="''${HOSTNAME:-$(${pkgs.coreutils}/bin/hostname)}"
    echo "[nixos-auto-update] Rebuilding host: ''${host}"
    /run/current-system/sw/bin/nixos-rebuild switch --flake "$workdir/nixosconfig#''${host}"

    ${lib.optionalString cfg.collectGarbage ''
      echo "[nixos-auto-update] Collecting old generations…"
      ${pkgs.nix}/bin/nix-collect-garbage -d
    ''}

    ${lib.optionalString cfg.trim ''
      echo "[nixos-auto-update] TRIM filesystems (ignore failures if unsupported)…"
      ${pkgs.util-linux}/sbin/fstrim -av || true
    ''}

    echo "[nixos-auto-update] Done."
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
      description = "Run fstrim -av after successful switch (ignored if unsupported).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixos-auto-update = {
      description = "Nightly flake switch from github.com/abl030/nixosconfig";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = updaterScript;

        # Own writable HOME/caches; avoid /root
        StateDirectory = "nixos-auto-update"; # /var/lib/nixos-auto-update
        CacheDirectory = "nixos-auto-update"; # /var/cache/nixos-auto-update
        WorkingDirectory = "/var/lib/nixos-auto-update";
        Environment = [
          "HOME=/var/lib/nixos-auto-update"
          "XDG_CONFIG_HOME=/var/lib/nixos-auto-update"
          "XDG_CACHE_HOME=/var/cache/nixos-auto-update"
          "GIT_TERMINAL_PROMPT=0"
        ];

        PrivateTmp = true;

        TimeoutStartSec = "3h";
        StandardOutput = "journal";
        StandardError = "journal";

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/nix" "/boot" "/etc" "/var" "/tmp"];
        CapabilityBoundingSet = [""];
        NoNewPrivileges = true;
        LockPersonality = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
      };
    };

    systemd.timers.nixos-auto-update = {
      description = "Run nixos-auto-update between 01:00–02:00 with jitter";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 01:00:00";
        RandomizedDelaySec = "60m"; # random start between 01:00 and 02:00
        AccuracySec = "1m";
        Persistent = true; # catch up if missed while powered off
      };
    };
  };
}
