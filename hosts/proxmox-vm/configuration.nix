{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../services/mounts/nfs_local.nix
    ../services/mounts/ext.nix
    ../services/mounts/fuse.nix
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
    ../../docker/youtarr/docker-compose.nix
    ../../docker/music/docker-compose.nix

    ../../modules/nixos/services/podcast.nix
  ];

  homelab = {
    # Base.nix enables ssh=true/secure=true.
    # We override secure to false here matching your previous config.
    ssh.secure = false;

    # Base.nix enables tailscale=true.

    pve.enable = true;

    # Base.nix enables update=true.
    # We just add specific timing/dates here.
    update = {
      updateDates = "03:00";
      gcDates = "03:30";
      rebootOnKernelUpdate = true;
    };

    cache = {
      enable = true;
      mirrorHost = "nix-mirror.ablz.au";
      localHost = "nixcache.ablz.au";
      nixServeSecretKeyFile = "/var/lib/nixcache/secret.key";
    };

    # Override profile from "internal" (base default) to "server"
    nixCaches.profile = "server";

    ci.rollingFlakeUpdate = {
      enable = true;
      repoDir = "/home/abl030/nixosconfig";
    };
    services.githubRunner = {
      enable = true;
      repoUrl = "https://github.com/abl030/nixosconfig";
      tokenFile = "/var/lib/github-runner/registration-token";
      runnerName = "proxmox-bastion";
    };
  };

  # Base.nix enables NetworkManager.
  # We just set interface specifics here.
  networking.interfaces.ens18.mtu = 1400;
  networking.firewall.enable = false;

  # VM Specifics
  services.qemuGuest.enable = true;

  # Workloads
  virtualisation.docker = {
    enable = true;
    liveRestore = false;
  };

  # ADD ONLY HOST SPECIFIC GROUPS
  users.users.abl030 = {
    extraGroups = ["libvirtd" "vboxusers" "docker"];
  };

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    butane
  ]);

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
