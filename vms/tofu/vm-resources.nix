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
    vmName = pve.name or name;
    diskInterface = pve.diskInterface or "virtio0";
    cloneFromTemplate = pve.cloneFromTemplate or true;
    ignoreInit = pve.ignoreInit or false;
    ignoreChanges =
      [
        "cpu[0].architecture"
        "vga"
      ]
      ++ lib.optional ignoreInit "initialization"
      ++ (pve.ignoreChangesExtra or []);
  in
    {
      name = vmName;
      node_name = proxmoxConfig.node;
      vm_id = pve.vmid;
      on_boot = false; # Don't auto-start until NixOS is installed

      inherit bios;

      cpu = {
        inherit (pve) cores;
        type = pve.cpuType or "x86-64-v2-AES";
      };

      memory = {
        dedicated = pve.memory;
      };

      # Only add disk if it's a standard size (not passthrough)
      disk = lib.optional (diskSize != null) {
        datastore_id = pve.storage or proxmoxConfig.defaultStorage;
        interface = diskInterface;
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

      # Support single virtiofs object or list of virtiofs mappings
      virtiofs = let
        raw = pve.virtiofs or [];
        normalized =
          if builtins.isList raw
          then raw
          else [raw];
      in
        map (
          vfs:
            {
              mapping = vfs.mapping or "containers";
            }
            // lib.optionalAttrs (vfs ? cache) {
              inherit (vfs) cache;
            }
            // lib.optionalAttrs (vfs ? direct_io) {
              inherit (vfs) direct_io;
            }
            // lib.optionalAttrs (vfs ? expose_acl) {
              inherit (vfs) expose_acl;
            }
            // lib.optionalAttrs (vfs ? expose_xattr) {
              inherit (vfs) expose_xattr;
            }
        )
        normalized;

      # Lifecycle rules
      lifecycle = {
        ignore_changes = ignoreChanges;
      };
    }
    // lib.optionalAttrs cloneFromTemplate {
      clone = {
        vm_id = proxmoxConfig.templateVmid;
        full = true;
        retries = 3;
      };
    }
    // lib.optionalAttrs (cloneFromTemplate || pve ? description) {
      description = pve.description or "Managed by OpenTofu - ${host.hostname}";
    }
    // lib.optionalAttrs (cloneFromTemplate || pve ? tags) {
      tags = pve.tags or ["opentofu" "nixos" "managed"];
    }
    // lib.optionalAttrs (bios == "ovmf") {
      efi_disk = {
        datastore_id = pve.storage or proxmoxConfig.defaultStorage;
        file_format = "raw";
        type = "4m";
      };
    }
    // lib.optionalAttrs (pve ? machine) {
      inherit (pve) machine;
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
