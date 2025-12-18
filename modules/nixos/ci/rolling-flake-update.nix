{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.ci.rollingFlakeUpdate or {};

  wrapperScript = pkgs.writeShellScript "rolling-flake-update-wrapper" ''
    set -euo pipefail
    if [ -n "''${GH_TOKEN_FILE-}" ]; then
      export GH_TOKEN="$(cat "''${GH_TOKEN_FILE}")"
    fi
    exec ${pkgs.bash}/bin/bash ./scripts/rolling_flake_update.sh
  '';
in {
  options.homelab.ci.rollingFlakeUpdate = {
    enable = lib.mkEnableOption "Daily rolling flake update (Update -> Build -> Push)";

    repoDir = lib.mkOption {
      type = lib.types.path;
      default = "/home/abl030/nixosconfig";
      description = "Local path to the repo.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File containing a GitHub PAT (needed for HTTPS push).";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "22:15"; # AWST
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.rolling-flake-update = {
      description = "Rolling flake update";
      wants = ["network-online.target"];
      after = ["network-online.target"];

      # ADDED: pkgs.bash so /usr/bin/env bash works in sub-scripts
      path = [pkgs.git pkgs.jq pkgs.nix pkgs.coreutils pkgs.openssh pkgs.bash];

      serviceConfig = {
        Type = "oneshot";
        User = "abl030";
        WorkingDirectory = cfg.repoDir;
        TimeoutStartSec = "4h";

        Environment =
          [
            "REPO_DIR=${cfg.repoDir}"
            "BASE_BRANCH=master"
          ]
          ++ lib.optionals (cfg.tokenFile != null) [
            "GH_TOKEN_FILE=${cfg.tokenFile}"
          ];

        ExecStart = wrapperScript;
      };
    };

    systemd.timers.rolling-flake-update = {
      description = "Daily rolling flake update";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        AccuracySec = "5m";
      };
    };
  };
}
