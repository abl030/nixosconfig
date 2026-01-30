{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.ci.rollingFlakeUpdate or {};
  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;

  wrapperScript = pkgs.writeShellScript "rolling-flake-update-wrapper" ''
    set -euo pipefail
    if [ -n "''${GH_TOKEN_FILE-}" ]; then
      export GH_TOKEN="$(cat "''${GH_TOKEN_FILE}")"
    fi
    log_file="$(/run/current-system/sw/bin/mktemp)"
    set +e
    ${pkgs.bash}/bin/bash ./scripts/rolling_flake_update.sh 2>&1 | /run/current-system/sw/bin/tee "$log_file"
    status=''${PIPESTATUS[0]}
    set -e
    /run/current-system/sw/bin/cat "$log_file"
    if [ "$status" -ne 0 ]; then
      token_file="''${GOTIFY_TOKEN_FILE:-${toString gotifyTokenFile}}"
      if [ -n "$token_file" ] && [ -r "$token_file" ]; then
        token="$(/run/current-system/sw/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$token_file")"
        if [ -n "$token" ]; then
          message_tail="$(/run/current-system/sw/bin/tail -n 120 "$log_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
          /run/current-system/sw/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
            -F "title=rolling flake update failed on ${config.networking.hostName}" \
            -F "message=$message_tail" \
            -F "priority=8" >/dev/null || true
        fi
      fi
    fi
    /run/current-system/sw/bin/rm -f "$log_file"
    exit "$status"
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
          ]
          ++ lib.optionals (gotifyTokenFile != null) [
            "GOTIFY_TOKEN_FILE=${gotifyTokenFile}"
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
