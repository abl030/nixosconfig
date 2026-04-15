{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    kernelPackages = pkgs.linuxPackages_latest;
    kernel.sysctl = {
      "fs.inotify.max_user_watches" = 2097152;
    };
    kernelParams = ["cgroup_disable=hugetlb"];
  };

  homelab = {
    openobserve = {
      enable = false;
      debug = false;
    };
    mounts = {
      nfsLocal.enable = true;
      fuse.enable = true;
    };
    containers = {
      enable = true;
    };
    services.tdarrNode.enable = true;
    services.jellyfin.enable = true;
    ssh = {
      enable = true;
      secure = false;
    };
    # Syslog receiver moved to doc2 with the LGTM stack (#208).
    tailscale.enable = true;
    mdnsReflector = {
      enable = true;
      interfaces = ["ens18"];
    };
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      # Kernel auto-reboot leaves the iGPU stuck without DRI devices
      # (amdgpu binds but DRM init fails). Only a Proxmox host reboot
      # recovers. See docs/wiki/infrastructure/igpu-passthrough.md.
      rebootOnKernelUpdate = false;
    };
  };

  hardware = {
    graphics.enable = true;
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };

  # ADD ONLY HOST SPECIFIC GROUPS
  users.users.abl030 = {
    extraGroups = ["video" "render"];
  };

  security.sudo.extraRules = lib.mkAfter [
    {
      users = ["abl030"];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    libva-utils
    radeontop
    nvtopPackages.amd
  ]);

  # Virtiofs mounts from prom. Music is the canonical 668GB ZFS child dataset;
  # media_metadata is the jellyfin-writable tree (NFOs, artwork, trickplay)
  # backed by nvmeprom/containers/media_metadata. Movies and TV Shows media
  # themselves continue to come from tower via NFS (see modules/nixos/services/mounts).
  fileSystems."/mnt/virtio/Music" = {
    device = "music";
    fsType = "virtiofs";
    options = ["rw" "relatime"];
  };
  fileSystems."/mnt/virtio/media_metadata" = {
    device = "media_metadata";
    fsType = "virtiofs";
    options = ["rw" "relatime"];
  };

  services.qemuGuest.enable = true;

  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
  system = {
    activationScripts.sopsAgeKey = {
      deps = ["specialfs"];
      text = ''
        if [ ! -s /var/lib/sops-nix/key.txt ]; then
          install -d -m 0700 /var/lib/sops-nix
          ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/sops-nix/key.txt
          chmod 600 /var/lib/sops-nix/key.txt
        fi
      '';
    };
    activationScripts.setupSecrets.deps = lib.mkBefore ["sopsAgeKey"];
    stateVersion = "25.05";
  };
}
