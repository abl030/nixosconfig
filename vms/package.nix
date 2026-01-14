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

  # Interactive VM definition + config creation
  new-vm = pkgs.writeShellApplication {
    name = "new-vm";

    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
      gnused
      gawk
      jq
      nix
      proxmox-ops
    ];

    text = ''
      # Source the new VM wizard
      ${builtins.readFile ./new.sh}
    '';

    meta = {
      description = "Interactive VM creation wizard";
      longDescription = ''
        Wizard that creates a new managed VM definition and host config,
        then runs provisioning on Proxmox.

        Usage:
          new-vm

        Example:
          new-vm
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
        Post-provisioning for OpenTofu VMs:
        1. Applies NixOS config to the blank VM
        2. Extracts SSH host key from the VM
        3. Updates hosts.nix with the new VM entry
        4. Converts SSH key to age key for sops
        5. Updates .sops.yaml with the new age key
        6. Re-encrypts all secrets
        7. Updates documentation

        Usage:
          post-provision-vm <vm-name> <vm-ip> <vmid>
          post-provision-vm <vm-name> <vmid>

        Examples:
          post-provision-vm test-vm 192.168.1.50 110
          post-provision-vm test-vm 110
      '';
    };
  };
}
