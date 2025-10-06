# ./modules/nixos/github-runner.nix
{
  lib,
  pkgs,
  config,
  ...
}:
/*
Self-hosted GitHub Actions runner.
This version embraces the module's defaults for simplicity and robustness.
- The module manages its own user and state directories.
- Ephemeral + replace provides job isolation and idempotency.
- We simply trust the group created by the module.
*/
let
  cfg = config.homelab.services.githubRunner or {};
in {
  options.homelab.services.githubRunner = {
    enable = lib.mkEnableOption "Enable the GitHub Actions runner";
    repoUrl = lib.mkOption {
      type = lib.types.str;
      description = "GitHub repo URL (e.g. https://github.com/abl030/nixosconfig).";
    };
    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the registration token file.";
      example = "/var/lib/github-runner/registration-token";
    };
    runnerName = lib.mkOption {
      type = lib.types.str;
      default = "proxmox-bastion";
      description = "Runner name (UI + unit suffix).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Let the module manage its own state directories. No tmpfiles rules needed.
    services.github-runners.${cfg.runnerName} = {
      enable = true;
      url = cfg.repoUrl;
      tokenFile = cfg.tokenFile;

      # The module creates a user/group named after the service (`github-runner-proxmox-bastion`),
      # so we don't need to define one manually.

      ephemeral = true;
      replace = true;

      # By not setting `workDir`, we use the module's default inside /var/lib, which it manages correctly.
      extraLabels = ["nix" "proxmox-vm"];
      extraPackages = [pkgs.git pkgs.gnutar pkgs.xz pkgs.cacert pkgs.nix pkgs.cachix];
    };

    # Trust the group the module creates. The group name is derived from the service name.
    nix.settings.trusted-users = ["@github-runner-${cfg.runnerName}"];
  };
}
