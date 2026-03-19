{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.ci.rollingFlakeUpdate or {};
  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;

  triageSystemPrompt = ''
    You are triaging a NixOS rolling flake update build failure.
    You receive the last 200 lines of build log via stdin.

    Output ONLY this format, nothing else:

    **Classification**: upstream | actionable
    **Summary**: 1-2 sentences describing what failed and why.
    **Fix**: If actionable, state the file and option to change. If upstream, say "wait for nixpkgs" and mention the relevant package/module.

    Rules:
    - "upstream" means the failure is in nixpkgs itself (e.g. broken package, upstream deprecation with no config-side fix yet). We just wait.
    - "actionable" means we need to change our flake config (e.g. removed option we still set, renamed module, missing input).
    - Keep total output under 500 characters.
    - Do not include markdown headers, preamble, or sign-off.
  '';

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
      set +e
      token_file="''${GOTIFY_TOKEN_FILE:-${toString gotifyTokenFile}}"
      if [ -n "$token_file" ] && [ -r "$token_file" ]; then
        token="$(/run/current-system/sw/bin/awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$token_file")"
        if [ -n "$token" ]; then
          # Triage the failure with Claude Code (headless, no API cost)
          summary="$(/run/current-system/sw/bin/tail -n 200 "$log_file" | \
            /run/current-system/sw/bin/timeout 600 claude -p \
            --system-prompt ${lib.escapeShellArg triageSystemPrompt} \
            --model haiku \
            --no-session-persistence \
            --tools "" \
            "Triage this NixOS build failure log from stdin." \
            2>/dev/null)"

          # Fall back to raw log tail if claude triage failed
          if [ -z "$summary" ]; then
            summary="(claude triage unavailable, raw log tail follows)"$'\n\n'"$(/run/current-system/sw/bin/tail -n 120 "$log_file" | /run/current-system/sw/bin/sed 's/[[:cntrl:]]/ /g')"
          fi

          /run/current-system/sw/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
            -F "title=rolling flake update failed on ${config.networking.hostName}" \
            -F "message=$summary" \
            -F "priority=8" >/dev/null || true
        fi
      fi
      set -e
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

      # Keep git's configured credential helper available inside the service.
      path = [pkgs.git pkgs.gh pkgs.jq pkgs.nix pkgs.coreutils pkgs.openssh pkgs.bash pkgs.claude-code];

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
