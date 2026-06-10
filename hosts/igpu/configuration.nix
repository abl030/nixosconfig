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
    services.tdarrNode.enable = true;
    services.jellyfin = {
      enable = true;
      # Service state on virtiofs (per docs/wiki/nixos-service-modules.md).
      dataRoot = "/mnt/virtio/jellyfin";
    };
    # OpenAI-compatible whisper.cpp endpoint, GPU-accelerated via the iGPU's
    # Vulkan backend. Lets Dictate Keyboard and anything else point at our
    # tailnet instead of Groq/OpenAI.
    services.whisper-server = {
      enable = true;
      dataDir = "/mnt/virtio/whisper-server";
      # Three concurrent backends with a dispatcher in front — switch in
      # Dictate by changing only the model field (small/medium/large).
      # large-v3-turbo is the default since small.en struggled with
      # car-cabin background noise; small + medium are there for low-latency
      # cases where speech is clean.
      models = {
        small = "tiny.en";
        medium = "small.en";
        large = "large-v3-turbo";
      };
      defaultModel = "large";
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

  # Passwordless `nixos-rebuild` used to live here for remote agent deploys.
  # Retired: igpu is now `sudoPasswordless = true` in hosts.nix (it is an
  # always-on server VM in the doc1/doc2 tier, and a passwordless rebuild is
  # already passwordless root). Full passwordless sudo supersedes the rule and
  # also unblocks `sudo fleet-update` for verified deploys.

  # igpu was the signed-fleet-deploys enforcement canary (Phase C, 2026-06-10):
  # verified deploy, freshness watchdog, break-glass, and accept-new-root were
  # all walked through end-to-end here. enforce + freshness.enable are now the
  # fleet default in modules/nixos/profiles/base.nix, so the per-host override
  # has been removed. See docs/wiki/infrastructure/signed-fleet-deploys.md.

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
