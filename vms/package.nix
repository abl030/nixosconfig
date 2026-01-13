# VM Provisioning Tools Package
# ==============================
#
# Nix packages for VM provisioning and management tools.
# Exports: provision-vm, post-provision-vm, proxmox-ops
{pkgs, ...}: rec {
  # Proxmox operations wrapper
  proxmox-ops = pkgs.writeShellApplication {
    name = "proxmox-ops";

    runtimeInputs = with pkgs; [
      openssh
      jq
      gawk
      coreutils
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
  };

  # Main VM provisioning orchestration
  provision-vm = pkgs.writeShellApplication {
    name = "provision-vm";

    runtimeInputs = with pkgs; [
      openssh
      jq
      coreutils
      git
      nix
      proxmox-ops # Include proxmox-ops in PATH
    ];

    text = ''
      # Source the provision script
      ${builtins.readFile ./provision.sh}
    '';

    meta = {
      description = "Provision a new VM from definition";
      longDescription = ''
        End-to-end VM provisioning orchestration.

        This script:
        1. Loads VM definition from vms/definitions.nix
        2. Clones from template and configures resources
        3. Sets up cloud-init with fleet SSH keys
        4. Starts VM and waits for network
        5. Provides instructions for NixOS installation

        Usage:
          provision-vm <vm-name>

        Example:
          provision-vm test-vm

        The VM must be defined in vms/definitions.nix under 'managed' section.
      '';
    };
  };

  # Post-provisioning fleet integration
  post-provision-vm = pkgs.writeShellApplication {
    name = "post-provision-vm";

    runtimeInputs = with pkgs; [
      openssh
      ssh-to-age
      sops
      git
      jq
      coreutils
      gawk
    ];

    text = ''
      # Source the post-provision script
      ${builtins.readFile ./post-provision.sh}
    '';

    meta = {
      description = "Post-provisioning fleet integration";
      longDescription = ''
        After NixOS is installed, this script:
        1. Extracts SSH host key from the VM
        2. Updates hosts.nix with the new VM entry
        3. Converts SSH key to age key for sops
        4. Updates .sops.yaml with the new age key
        5. Re-encrypts all secrets
        6. Updates documentation
        7. Commits changes to git

        Usage:
          post-provision-vm <vm-name> <vm-ip> <vmid>

        Example:
          post-provision-vm test-vm 192.168.1.50 110
      '';
    };
  };
}
