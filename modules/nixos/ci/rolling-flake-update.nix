# modules/nixos/ci/rolling-flake-update.nix
{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.ci.rollingFlakeUpdate or {};

  # Wrapper reads an optional token file into GH_TOKEN and then calls your script.
  # IMPORTANT: Bash parameter expansions like ${VAR-} must be escaped as ''${VAR-}
  # inside Nix strings to avoid Nix interpolation.
  wrapperScript = pkgs.writeShellScript "rolling-flake-update-wrapper" ''
    set -euo pipefail
    if [ -n "''${GH_TOKEN_FILE-}" ]; then
      export GH_TOKEN="$(cat "''${GH_TOKEN_FILE}")"
    fi
    exec ${pkgs.bash}/bin/bash ./scripts/rolling_flake_update.sh
  '';
in {
  options.homelab.ci.rollingFlakeUpdate = {
    enable = lib.mkEnableOption "Daily rolling flake update PR";

    repoDir = lib.mkOption {
      type = lib.types.path;
      default = "/home/abl030/nixosconfig";
      description = "Local path to the repo.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null; # If null, gh must already be authenticated
      description = "File containing a PAT with repo scope for gh (optional).";
    };

    gitUserName = lib.mkOption {
      type = lib.types.str;
      default = "nix bot";
    };

    gitUserEmail = lib.mkOption {
      type = lib.types.str;
      default = "acme@ablz.au";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "22:15";
      description = "Systemd OnCalendar time (AWST).";
    };

    baseBranch = lib.mkOption {
      type = lib.types.str;
      default = "master";
    };

    prBranch = lib.mkOption {
      type = lib.types.str;
      default = "bot/rolling-flake-update";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.rolling-flake-update = {
      description = "Rolling flake update PR";
      wants = ["network-online.target"];
      after = ["network-online.target"];

      # Provide tools on PATH for the script.
      path = [pkgs.git pkgs.jq pkgs.gh pkgs.nix];

      serviceConfig = {
        Type = "oneshot";
        User = "abl030";
        WorkingDirectory = cfg.repoDir;

        # Stable, explicit environment.
        Environment =
          [
            "REPO_DIR=${cfg.repoDir}"
            "BASE_BRANCH=${cfg.baseBranch}"
            "PR_BRANCH=${cfg.prBranch}"
            "GIT_USER_NAME=${cfg.gitUserName}"
            "GIT_USER_EMAIL=${cfg.gitUserEmail}"
          ]
          ++ lib.optionals (cfg.tokenFile != null) [
            "GH_TOKEN_FILE=${cfg.tokenFile}"
          ];

        ExecStart = wrapperScript;
      };
    };

    systemd.timers.rolling-flake-update = {
      description = "Daily rolling flake update PR";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        AccuracySec = "5m";
      };
    };
  };
}
