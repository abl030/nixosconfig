{
  lib,
  config,
  pkgs,
  allHosts,
  ...
}: let
  signing = import ../../../nix/fleet-signing.nix {inherit lib;};
  cfg = config.homelab.update.verify;
  etcPath = lib.removePrefix "/etc/" cfg.allowedSignersPath;
  fleetUpdateSource = builtins.path {
    path = ./fleet-update.sh;
    name = "fleet-update.sh";
  };
  originsString = lib.concatStringsSep " " (lib.mapAttrsToList (name: url: "${name}=${url}") cfg.origins);
  rebuildFlags = lib.concatStringsSep " " config.system.autoUpgrade.flags;
  freshnessCheck = pkgs.writeShellApplication {
    name = "fleet-update-freshness-check";
    runtimeInputs = with pkgs; [
      coreutils
      jq
    ];
    text = ''
      marker=${lib.escapeShellArg cfg.lastVerifiedFreshnessFile}
      max_age=${toString cfg.freshness.maxAgeSeconds}
      now="$(date -u +%s)"

      fail() {
        echo "FLEET-FRESHNESS FAIL $*"
      }

      if [ ! -s "$marker" ]; then
        fail "missing verified freshness marker: $marker"
        exit 0
      fi

      if ! heartbeat_epoch="$(jq -er '.heartbeat_epoch | numbers | floor' "$marker" 2>/dev/null)"; then
        fail "malformed verified freshness marker: $marker"
        exit 0
      fi

      target="$(jq -r '.target // "unknown"' "$marker" 2>/dev/null || echo unknown)"
      heartbeat_commit="$(jq -r '.heartbeat_commit // "unknown"' "$marker" 2>/dev/null || echo unknown)"
      age=$((now - heartbeat_epoch))
      if [ "$age" -gt "$max_age" ]; then
        fail "stale signed heartbeat age_seconds=$age max_age_seconds=$max_age target=$target heartbeat_commit=$heartbeat_commit"
        exit 0
      fi

      echo "FLEET-FRESHNESS OK age_seconds=$age max_age_seconds=$max_age target=$target heartbeat_commit=$heartbeat_commit"
    '';
  };
  fleetUpdate = pkgs.writeShellApplication {
    name = "fleet-update";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      git
      gnugrep
      gnused
      jq
      nix
      openssh
    ];
    text = ''
      export PATH="/run/current-system/sw/bin:$PATH"
      export FLEET_UPDATE_ALLOWED_SIGNERS_FILE=${lib.escapeShellArg cfg.allowedSignersPath}
      export FLEET_UPDATE_STATE_DIR=${lib.escapeShellArg cfg.stateDir}
      export FLEET_UPDATE_REPO_DIR=${lib.escapeShellArg cfg.repoDir}
      export FLEET_UPDATE_LAST_VERIFIED_REV_FILE=${lib.escapeShellArg cfg.lastVerifiedRevFile}
      export FLEET_UPDATE_LAST_SOURCE_CONTACT_FILE=${lib.escapeShellArg cfg.lastSourceContactFile}
      export FLEET_UPDATE_LAST_VERIFIED_FRESHNESS_FILE=${lib.escapeShellArg cfg.lastVerifiedFreshnessFile}
      export FLEET_UPDATE_HIGHEST_SEEN_HEARTBEAT_FILE=${lib.escapeShellArg cfg.highestSeenHeartbeatFile}
      export FLEET_UPDATE_ORIGINS=${lib.escapeShellArg originsString}
      export FLEET_UPDATE_WRITE_ROOT=${lib.escapeShellArg cfg.writeRoot}
      export FLEET_UPDATE_BRANCH=${lib.escapeShellArg cfg.branch}
      export FLEET_UPDATE_HOSTNAME=${lib.escapeShellArg config.networking.hostName}
      export FLEET_UPDATE_HEARTBEAT_FILE=${lib.escapeShellArg cfg.heartbeatFile}
      export FLEET_UPDATE_BOT_PRINCIPAL=${lib.escapeShellArg cfg.botPrincipal}
      export FLEET_UPDATE_FRESHNESS_MAX_AGE_SECONDS=${toString cfg.freshness.maxAgeSeconds}
      export FLEET_UPDATE_REBUILD_BIN=${lib.escapeShellArg "${config.system.build.nixos-rebuild}/bin/nixos-rebuild"}
      export FLEET_UPDATE_REBUILD_FLAGS=${lib.escapeShellArg rebuildFlags}
      exec ${pkgs.bash}/bin/bash ${fleetUpdateSource} "$@"
    '';
  };
in {
  # Trust model and recovery procedures:
  # docs/wiki/infrastructure/signed-fleet-deploys.md
  options.homelab.update.verify = {
    enable = lib.mkEnableOption "signed fleet update verification trust anchor" // {default = true;};

    enforce = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use fleet-update for nixos-upgrade.service instead of the raw GitHub flake path.";
    };

    allowedSignersPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/fleet-update/allowed_signers";
      description = "Path to the OpenSSH allowed_signers file used for fleet update verification.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fleet-update";
      description = "State directory for the verified fleet update clone and anchors.";
    };

    repoDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fleet-update/repo";
      description = "Full local git checkout used for verified fleet updates.";
    };

    lastVerifiedRevFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fleet-update/last-verified-rev";
      description = "Durable fallback anchor written after a successful verified activation.";
    };

    lastSourceContactFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fleet-update/last-source-contact";
      description = "Marker written when fleet-update fetched and signature-verified at least one configured origin.";
    };

    lastVerifiedFreshnessFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fleet-update/last-verified-freshness";
      description = "Marker containing the most recent authenticated freshness heartbeat accepted by fleet-update.";
    };

    highestSeenHeartbeatFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fleet-update/highest-seen-heartbeat";
      description = "Monotonic heartbeat epoch guard used to reject replayed older freshness markers.";
    };

    heartbeatFile = lib.mkOption {
      type = lib.types.str;
      default = "fleet/freshness.json";
      description = "Repo-relative signed heartbeat file maintained by the rolling flake update bot.";
    };

    botPrincipal = lib.mkOption {
      type = lib.types.str;
      default = "nix bot <acme@ablz.au>";
      description = "Allowed-signers principal required for commits that update the freshness heartbeat file.";
    };

    origins = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        github = "https://github.com/abl030/nixosconfig.git";
      };
      description = "Named fetch origins used by fleet-update. Names become git remote names.";
    };

    writeRoot = lib.mkOption {
      type = lib.types.str;
      default = "github";
      description = "Origin whose protected branch must contain the selected deployment target.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "master";
      description = "Branch verified by fleet-update for normal deployments.";
    };

    freshness = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable the local signed-heartbeat staleness watchdog timer.";
      };

      maxAgeSeconds = lib.mkOption {
        type = lib.types.int;
        default =
          if config.homelab.update.checkAcPower
          then 72 * 60 * 60
          else 30 * 60 * 60;
        description = "Maximum accepted age for the signed rolling bot heartbeat.";
      };

      checkInterval = lib.mkOption {
        type = lib.types.str;
        default = "hourly";
        description = "OnCalendar expression for the local signed-heartbeat freshness watchdog.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/etc/" cfg.allowedSignersPath;
        message = "homelab.update.verify.allowedSignersPath must live under /etc";
      }
      {
        assertion = signing.validationErrors allHosts == [];
        message = "fleet signing hosts.nix validation failed: ${lib.concatStringsSep "; " (signing.validationErrors allHosts)}";
      }
      {
        assertion = lib.hasAttr cfg.writeRoot cfg.origins;
        message = "homelab.update.verify.writeRoot must name one of homelab.update.verify.origins";
      }
      {
        assertion = lib.all (name: builtins.match "[A-Za-z0-9._-]+" name != null) (lib.attrNames cfg.origins);
        message = "homelab.update.verify.origins names must be valid git remote names";
      }
    ];

    environment.etc.${etcPath} = {
      text = signing.allowedSignersText allHosts;
      mode = "0644";
    };

    environment.systemPackages = [fleetUpdate freshnessCheck];

    system.build.fleetUpdate = fleetUpdate;
    system.build.fleetUpdateFreshnessCheck = freshnessCheck;

    systemd = {
      services.fleet-update-freshness = {
        description = "Check signed fleet update heartbeat freshness";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe freshnessCheck;
          StandardOutput = "journal";
          StandardError = "journal";
        };
      };

      timers.fleet-update-freshness = lib.mkIf cfg.freshness.enable {
        description = "Periodic signed fleet update heartbeat freshness check";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.freshness.checkInterval;
          Persistent = true;
          RandomizedDelaySec = "10m";
        };
      };

      tmpfiles.rules = [
        "d ${cfg.stateDir} 0700 root root -"
      ];
    };

    homelab.monitoring.errorPatterns = [
      {
        name = "Fleet update freshness stale";
        unit = "(nixos-upgrade|fleet-update-freshness)\\.service";
        unitIsRegex = true;
        pattern = "FLEET-FRESHNESS FAIL";
        severity = "warning";
        summary = "signed fleet update heartbeat is missing, stale, replayed, or not bot-signed";
        threshold = 0;
        description = ''
          fleet-update could not authenticate a fresh green
          ${cfg.heartbeatFile} heartbeat signed by ${cfg.botPrincipal}, or
          the local freshness watchdog found the accepted heartbeat older
          than ${toString cfg.freshness.maxAgeSeconds}s. This is the
          anti-freeze backstop for stale origin replay and quiet-skip
          scenarios; inspect /var/lib/fleet-update/* and the matched log line.
        '';
      }
    ];
  };
}
