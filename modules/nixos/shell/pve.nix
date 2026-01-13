# Proxmox CLI Wrapper Module
# Provides the 'pve' command for ergonomic Proxmox VM management
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.pve;

  # Package the pve script
  pve-cli = pkgs.writeScriptBin "pve" (builtins.readFile ../../../scripts/pve);
in {
  options.homelab.pve = {
    enable = mkEnableOption "Proxmox CLI wrapper (pve command)";
  };

  config = mkIf cfg.enable {
    # Make pve command available system-wide
    environment.systemPackages =
      [
        pve-cli
        pkgs.jq # Required for pve's jq formatting
        pkgs.util-linux # Provides column command for table formatting
      ]
      ++ (
        if pathExists ../../../vms/proxmox-ops.sh
        then [pkgs.openssh pkgs.bash]
        else []
      );
  };
}
