{pkgs, ...}: {
  imports = [
    ./hardware-configuration.nix
    ../services/mounts/nfs_local.nix
    ../services/mounts/ext.nix
    # REMOVED: ../common/configuration.nix
    ../../docker/tailscale/caddy/docker-compose.nix
    ../../docker/immich/docker-compose.nix
    ../../docker/management/docker-compose.nix
    ../../docker/netboot/docker-compose.nix
    ../../docker/audiobookshelf/docker-compose.nix
    ../../docker/kopia/docker-compose.nix
    ../../docker/paperless/docker-compose.nix
    ../../docker/WebDav/docker-compose.nix
    ../../docker/atuin/docker-compose.nix
    ../../docker/StirlingPDF/docker-compose.nix
    ../../docker/mealie/docker-compose.nix
    ../../docker/jdownloader2/docker-compose.nix
    ../../docker/smokeping/docker-compose.nix
    ../../docker/tautulli/docker-compose.nix
    ../../docker/invoices/docker-compose.nix
    ../../docker/domain-monitor/docker-compose.nix
    ../../docker/uptime-kuma/docker-compose.nix
    ../../modules/nixos/services/podcast.nix
  ];

  homelab = {
    ci.rollingFlakeUpdate = {
      enable = true;
      repoDir = "/home/abl030/nixosconfig";
    };
    ssh = {
      enable = true;
      secure = false;
    };
    tailscale.enable = true;
    update = {
      enable = true;
      collectGarbage = true;
      updateDates = "03:00";
      gcDates = "03:30";
      trim = true;
      rebootOnKernelUpdate = true;
    };
    cache = {
      enable = true;
      mirrorHost = "nix-mirror.ablz.au";
      localHost = "nixcache.ablz.au";
      nixServeSecretKeyFile = "/var/lib/nixcache/secret.key";
    };
    nixCaches = {
      enable = true;
      profile = "server";
    };
    services.githubRunner = {
      enable = true;
      repoUrl = "https://github.com/abl030/nixosconfig";
      tokenFile = "/var/lib/github-runner/registration-token";
      runnerName = "proxmox-bastion";
    };
  };

  virtualisation.docker = {
    enable = true;
    liveRestore = false;
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelParams = ["cgroup_disable=hugetlb"];
  };

  networking = {
    networkmanager.enable = true;
    hostName = "proxmox-vm";
    firewall.enable = false;
    interfaces.ens18.mtu = 1400;
  };

  services = {
    qemuGuest.enable = true;
    fstrim.enable = true;
    openssh.enable = true;
  };

  # ADD ONLY HOST SPECIFIC GROUPS
  users.users.abl030 = {
    extraGroups = ["libvirtd" "vboxusers" "docker"];
  };

  environment.systemPackages = with pkgs; [
    butane
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
  };

  system.stateVersion = "24.05";
}
