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
    path = ../../../scripts/fleet_update.sh;
    name = "fleet-update.sh";
  };
  originsString = lib.concatStringsSep " " (lib.mapAttrsToList (name: url: "${name}=${url}") cfg.origins);
  rebuildFlags = lib.concatStringsSep " " config.system.autoUpgrade.flags;
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
      export FLEET_UPDATE_ORIGINS=${lib.escapeShellArg originsString}
      export FLEET_UPDATE_WRITE_ROOT=${lib.escapeShellArg cfg.writeRoot}
      export FLEET_UPDATE_BRANCH=${lib.escapeShellArg cfg.branch}
      export FLEET_UPDATE_HOSTNAME=${lib.escapeShellArg config.networking.hostName}
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
