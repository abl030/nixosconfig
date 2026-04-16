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
    mounts = {
      nfsLocal.enable = true;
      fuse.enable = true;
    };
    # Rootless compose retired (#208 Phase 3): jellyfin is native,
    # tdarr-node uses homelab.podman (rootful OCI). No more compose stacks.
    containers.enable = false;
    services.tdarrNode.enable = true;
    services.jellyfin = {
      enable = true;
      # Service state on virtiofs (per .claude/rules/nixos-service-modules.md).
      dataRoot = "/mnt/virtio/jellyfin";
    };
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

  # Single broad virtiofs mount of the prom `containers` ZFS dataset (matches
  # doc1/doc2 pattern). Service state for jellyfin/etc. lives under
  # /mnt/virtio/<service>/. Music + media_metadata are ZFS child datasets of
  # containers and appear automatically as /mnt/virtio/Music and
  # /mnt/virtio/media_metadata via virtiofs submount propagation — no
  # separate fileSystems entries needed for them.
  # See docs/wiki/infrastructure/media-filesystem.md.
  fileSystems."/mnt/virtio" = {
    device = "containers";
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
