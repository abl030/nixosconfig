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

  # Import VM tools to get proxmox-ops
  vmTools = import ../../../vms/package.nix {inherit pkgs;};

  # Package the pve script with proxmox-ops in PATH
  pve-cli = pkgs.writeShellApplication {
    name = "pve";
    runtimeInputs = with pkgs; [
      vmTools.proxmox-ops
      jq
      util-linux
      openssh
      bash
      bc # For floating point calculations
      coreutils # For date, sleep, etc
      nix # For nix run commands
    ];
    text = builtins.readFile ../../../scripts/pve;
  };
in {
  options.homelab.pve = {
    enable = mkEnableOption "Proxmox CLI wrapper (pve command)";
  };

  config = mkIf cfg.enable {
    # Make pve command available system-wide
    # All dependencies are bundled in pve-cli via writeShellApplication
    environment.systemPackages = lib.mkOrder 2000 [pve-cli];
  };
}
