# Generate Proxmox VM resources from hosts.nix
{
  lib,
  proxmoxConfig,
  proxmoxHosts,
  ...
}: let
  inherit (lib) mapAttrs' nameValuePair removeSuffix;

  # Convert disk size string to number (e.g., "64G" -> 64)
  parseDiskSize = disk: let
    stripped = removeSuffix "G" disk;
  in
    if stripped == disk
    then null # Not a standard disk (e.g., "passthrough")
    else lib.toInt stripped;

  # Generate a VM resource from a host definition
  mkVMResource = name: host: let
    pve = host.proxmox;
    diskSize = parseDiskSize pve.disk;
    bios = pve.bios or "seabios";
  in
    {
      inherit name;
      node_name = proxmoxConfig.node;
      vm_id = pve.vmid;
      description = "Managed by OpenTofu - ${host.hostname}";
      tags = ["opentofu" "nixos" "managed"];
      on_boot = false; # Don't auto-start until NixOS is installed

      inherit bios;

      clone = {
        vm_id = proxmoxConfig.templateVmid;
        full = true;
        retries = 3;
      };

      cpu = {
        inherit (pve) cores;
        type = "x86-64-v2-AES";
      };

      memory = {
        dedicated = pve.memory;
      };

      # Only add disk if it's a standard size (not passthrough)
      disk = lib.optional (diskSize != null) {
        datastore_id = pve.storage or proxmoxConfig.defaultStorage;
        interface = "virtio0";
        size = diskSize;
        file_format = "raw";
      };

      network_device = [
        {
          bridge = "vmbr0";
          model = "virtio";
        }
      ];

      agent = {
        enabled = true;
      };

      # Lifecycle rules
      lifecycle = {
        ignore_changes = ["cpu[0].architecture"];
      };
    }
    // lib.optionalAttrs (bios == "ovmf") {
      efi_disk = {
        datastore_id = pve.storage or proxmoxConfig.defaultStorage;
        file_format = "raw";
        type = "4m";
      };
    };
in {
  # Generate resource blocks for each managed VM
  resource.proxmox_virtual_environment_vm =
    mapAttrs' (
      name: host:
        nameValuePair name (mkVMResource name host)
    )
    proxmoxHosts;

  # Output VM information for use in provisioning scripts
  output =
    mapAttrs' (
      name: _:
        nameValuePair "${name}_ip" {
          value = "\${proxmox_virtual_environment_vm.${name}.ipv4_addresses[1][0]}";
          description = "IP address of ${name} VM";
        }
    )
    proxmoxHosts;
}
