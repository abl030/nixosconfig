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
  # system.autoUpgrade.flags is NOT just what update.nix sets: the upstream
  # nixpkgs auto-upgrade module appends `--refresh --flake <cfg.flake>` (the
  # frozen GitHub ref) to the merged option value. fleet-update.sh passes
  # REBUILD_FLAGS *after* its own `--flake <verified local clone>`, and the
  # last --flake wins in nixos-rebuild — so passing the merged flags through
  # made every enforced deploy verify Forgejo and then silently rebuild the
  # frozen GitHub rev (caught 2026-06-11: doc2 pinned to the cutover closure
  # while fleet-update reported success and advanced the anchor). Strip any
  # `--flake <ref>` pair; the verified clone ref from fleet-update.sh is the
  # only flake selector allowed on the enforced path.
  # Upstream appends the ref as a single element ("--flake github:...");
  # handle the two-element form too in case that ever changes.
  stripFlakeFlag = flags:
    if flags == []
    then []
    else if lib.head flags == "--flake"
    then stripFlakeFlag (lib.drop 2 flags)
    else if lib.hasPrefix "--flake " (lib.head flags)
    then stripFlakeFlag (lib.tail flags)
    else [(lib.head flags)] ++ stripFlakeFlag (lib.tail flags);
  rebuildFlags = lib.concatStringsSep " " (stripFlakeFlag config.system.autoUpgrade.flags);
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
      export FLEET_UPDATE_TOLERATE_USER_UNIT_FAILURE=${
        if config.homelab.update.tolerateUserUnitFailure
        then "1"
        else "0"
      }
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

    # The hourly fleet-update-freshness watchdog timer + its paging errorPattern
    # were removed 2026-06-13: a missed bot push made every host warn hourly on
    # top of the rolling-flake-update failure alert (duplicate noise). The
    # in-deploy freshness verification in fleet-update.sh remains — fail-open,
    # journal/Loki-only ("FLEET-FRESHNESS FAIL"), no paging.
    freshness = {
      maxAgeSeconds = lib.mkOption {
        type = lib.types.int;
        default =
          if config.homelab.update.checkAcPower
          then 72 * 60 * 60
          else 30 * 60 * 60;
        description = "Maximum accepted age for the signed rolling bot heartbeat.";
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

    environment.systemPackages = [fleetUpdate];

    system.build.fleetUpdate = fleetUpdate;

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root -"
    ];
  };
}
