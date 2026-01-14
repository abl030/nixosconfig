# VM Definitions for Proxmox Infrastructure
# ========================================
#
# DEPRECATION NOTICE: This file is being superseded by hosts.nix
# The VM specs (vmid, cores, memory, disk) are now defined in hosts.nix
# under the 'proxmox' attribute. This file is kept for:
# - Extended documentation (services, notes, purpose)
# - Backwards compatibility with existing provision scripts
#
# See hosts.nix for the canonical VM configuration.
# OpenTofu/Terranix reads from hosts.nix directly.
#
# Structure:
# - imported: Pre-existing VMs that are documented but NOT managed by automation
# - managed: VMs provisioned and managed through this automation system
# - template: Base template used for cloning new VMs
#
# SAFETY: imported VMs have readonly=true to prevent accidental modifications
{
  # Proxmox Connection Configuration
  proxmox = {
    host = "192.168.1.12";
    node = "prom";
    user = "root";
    defaultStorage = "nvmeprom"; # ZFS pool with ~3.5TB available
  };

  # IMPORTED VMs - Pre-existing, read-only for documentation
  # These VMs exist in Proxmox but are NOT managed by this automation.
  # They are documented here for inventory and knowledge base purposes only.
  # The readonly flag prevents any lifecycle operations (start/stop/destroy/modify).
  imported = {
    doc1 = {
      vmid = 104;
      hostname = "proxmox-vm"; # hostname in hosts.nix
      sshAlias = "doc1"; # from hosts.nix
      status = "running";

      specs = {
        cores = 8;
        memory = 32768; # 32GB
        disk = "250G";
        storage = "nvmeprom";
      };

      purpose = "Main services VM - Docker workloads and CI/CD";

      services = [
        # Network
        "Tailscale + Caddy (reverse proxy)"
        # Media & Files
        "Immich (photo management)"
        "Audiobookshelf"
        "StirlingPDF"
        "WebDAV"
        # Infrastructure
        "NetBoot (PXE server)"
        "Kopia (backups)"
        "GitHub Actions runner (proxmox-bastion)"
        # Monitoring & Management
        "Uptime Kuma"
        "Smokeping"
        "Tautulli"
        "Domain Monitor"
        # Applications
        "Paperless"
        "Atuin (shell history sync)"
        "Mealie (recipes)"
        "Jdownloader2"
        "Invoices"
        "Youtarr"
        "Music services"
      ];

      notes = [
        "Runs daily auto-updates at 03:00 with GC at 03:30"
        "Serves as Nix cache server (nixcache.ablz.au)"
        "Rolling flake updates enabled"
        "MTU 1400 on ens18"
      ];

      readonly = true; # CRITICAL: Prevents automation from touching this VM
    };

    igp = {
      vmid = 109;
      hostname = "igpu"; # hostname in hosts.nix
      sshAlias = "igp"; # from hosts.nix
      status = "running";

      specs = {
        cores = 8;
        memory = 8096; # ~8GB
        disk = "passthrough"; # No dedicated disk, uses passthrough
        storage = "nvmeprom";
      };

      hardware = {
        gpu = "AMD 9950X integrated graphics (iGPU passthrough)";
        kernel = "linuxPackages_latest";
        notes = [
          "Uses vendor-reset DKMS module for GPU reset"
          "vBIOS file: /usr/share/kvm/vbios_9950x.rom on host"
          "User groups: docker, video, render"
        ];
      };

      purpose = "Media transcoding with AMD iGPU passthrough";

      services = [
        "Jellyfin (media server)"
        "Plex"
        "Tdarr (transcoding pipeline)"
        "Management stack for iGPU monitoring"
      ];

      monitoring = [
        "libva-utils"
        "radeontop"
        "nvtop (AMD variant)"
      ];

      notes = [
        "Latest kernel for AMD iGPU support"
        "inotify watches increased to 2097152"
        "Auto-updates enabled with reboot on kernel update"
      ];

      readonly = true; # CRITICAL: Prevents automation from touching this VM
    };
  };

  # MANAGED VMs - Provisioned and managed by this automation
  # Add new VMs here. They will be created, configured, and tracked.
  # These VMs are fully managed: creation, updates, and lifecycle.
  managed = {
    dev = {
      vmid = 110;
      cores = 4;
      memory = 8192; # MB
      disk = "64G";
      storage = "nvmeprom";
      nixosConfig = "dev";
      purpose = "Development VM";
      services = ["Development" "Testing"];
    };
  };

  # Template Configuration
  # This template is cloned when creating new VMs
  template = {
    vmid = 9002;
    name = "ubuntu-cloud-template";
    description = "Ubuntu cloud image with cloud-init for bootstrapping";
    specs = {
      cores = 2;
      memory = 2048;
      disk = "3584M"; # Base Ubuntu cloud image, will be resized during provisioning
    };
    notes = [
      "Cloud-init pre-configured - SSH keys injected automatically"
      "QEMU guest agent enabled for IP detection"
      "nixos-anywhere replaces Ubuntu with NixOS after SSH bootstrap"
    ];
  };

  # Reserved VMID Ranges
  # Document VMID allocation strategy to avoid conflicts
  vmidRanges = {
    production = {
      start = 100;
      end = 199;
      description = "Production VMs and services";
    };
    containers = {
      start = 200;
      end = 299;
      description = "LXC containers";
    };
    templates = {
      start = 9000;
      end = 9999;
      description = "VM templates for cloning";
    };
  };
}
