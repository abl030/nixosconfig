{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.ci.rollingFlakeUpdate or {};
  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;

  # Per-group failure triage prompt. The script (scripts/rolling_flake_update.sh)
  # runs this against each FAILED group's build log and bundles the summaries into
  # one Gotify notification. Kept as a file so the multi-line prompt survives env.
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
    - Keep total output under 400 characters.
    - Do not include markdown headers, preamble, or sign-off.
  '';
  triagePromptFile = pkgs.writeText "rolling-flake-update-triage-prompt" triageSystemPrompt;

  # Thin wrapper: just hand off to the repo script (which owns groups, build,
  # commit/push, and the single bundled notification). Env is supplied by the unit.
  wrapperScript = pkgs.writeShellScript "rolling-flake-update-wrapper" ''
    set -uo pipefail
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
      default = "23:00"; # AWST — late enough that interactive coding/pushes are done
    };

    groups = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {
        # nixpkgs + home-manager move together (HM is version-coupled to nixpkgs).
        # Run first so the llm/rest groups build on the cached new world.
        core = ["nixpkgs" "home-manager"];
        # LLM tooling ships ~daily and is near-self-contained — always gets through
        # even when core/rest are red, so we keep the latest models.
        llm = [
          "claude-code-nix"
          "codex-cli-nix"
          "claude-plugin-compound-engineering"
          "claude-plugin-ha-skills"
        ];
        # "rest" is implicit and COMPUTED in the script (all inputs - core - llm),
        # so newly-added flake inputs fall into it automatically.
      };
      description = ''
        Named input groups for the rolling update. Each group is updated and
        build-tested independently; a failing group is reverted while the others
        still commit. The "rest" group is computed (all inputs minus these), so it
        is intentionally not listed here. See GitHub issue #260.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.rolling-flake-update = {
      description = "Rolling flake update";
      wants = ["network-online.target"];
      after = ["network-online.target"];

      # Keep git's configured credential helper available inside the service.
      # curl/gawk/gnused/gnugrep are used by scripts/rolling_flake_update.sh for
      # triage + the bundled Gotify notification.
      path = [pkgs.git pkgs.gh pkgs.jq pkgs.nix pkgs.coreutils pkgs.openssh pkgs.bash pkgs.claude-code pkgs.curl pkgs.gawk pkgs.gnused pkgs.gnugrep];

      serviceConfig = {
        Type = "oneshot";
        User = "abl030";
        WorkingDirectory = cfg.repoDir;
        TimeoutStartSec = "4h";

        ExecStart = wrapperScript;
      };

      # Use the `environment` attrset (NOT serviceConfig.Environment) so values
      # containing spaces — the space-separated group lists — are quoted correctly.
      # systemd's Environment= splits on whitespace and would mangle them.
      environment =
        {
          REPO_DIR = cfg.repoDir;
          BASE_BRANCH = "master";
          RFU_HOSTNAME = config.networking.hostName;
          RFU_TRIAGE_PROMPT_FILE = "${triagePromptFile}";
          RFU_GROUP_CORE = lib.concatStringsSep " " (cfg.groups.core or []);
          RFU_GROUP_LLM = lib.concatStringsSep " " (cfg.groups.llm or []);
        }
        // lib.optionalAttrs (gotifyUrl != null) {
          GOTIFY_URL = gotifyUrl;
        }
        // lib.optionalAttrs (cfg.tokenFile != null) {
          GH_TOKEN_FILE = "${cfg.tokenFile}";
        }
        // lib.optionalAttrs (gotifyTokenFile != null) {
          GOTIFY_TOKEN_FILE = "${gotifyTokenFile}";
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
