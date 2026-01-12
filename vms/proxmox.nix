# Proxmox Operations Package
# ==========================
#
# Nix package that wraps proxmox-ops.sh for use in the flake.
# Provides SSH-based Proxmox VM management operations.

{ pkgs, ... }:

pkgs.writeShellApplication {
  name = "proxmox-ops";

  runtimeInputs = with pkgs; [
    openssh     # SSH client
    jq          # JSON parsing
    gawk        # Text processing
    coreutils   # Basic utilities
  ];

  text = builtins.readFile ./proxmox-ops.sh;

  meta = {
    description = "Proxmox VM operations via SSH";
    longDescription = ''
      Wrapper script for Proxmox qm commands via SSH.
      Provides safety checks for readonly/imported VMs.

      Usage:
        proxmox-ops list                    # List all VMs
        proxmox-ops status <vmid>           # Get VM status
        proxmox-ops clone <template> <new>  # Clone from template
        proxmox-ops start <vmid>            # Start VM
        ... and more
    '';
  };
}
