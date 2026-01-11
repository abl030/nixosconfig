{pkgs, ...}: {
  imports = [
    ./hardware-configuration.nix
    ../services/mounts/nfs_local.nix
    ../services/mounts/fuse.nix
    ../../docker/jellyfinn/docker-compose.nix
    ../../docker/management/igpu/docker_compose.nix
    ../../docker/plex/docker-compose.nix
    ../../docker/tdarr/igp/docker-compose.nix
  ];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    # kernelPackages = pkgs.linuxPackages_latest;
    kernel.sysctl = {
      "fs.inotify.max_user_watches" = 2097152;
    };
    kernelParams = ["cgroup_disable=hugetlb"];
  };

  homelab = {
    ssh = {
      enable = true;
      secure = false;
    };
    tailscale.enable = true;
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      rebootOnKernelUpdate = false;
    };
  };

  hardware = {
    graphics.enable = true;
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };

  virtualisation.docker.enable = true;

  # ADD ONLY HOST SPECIFIC GROUPS
  users.users.abl030 = {
    extraGroups = ["docker" "video" "render"];
  };

  environment.systemPackages = with pkgs; [
    libva-utils
    radeontop
    nvtopPackages.amd
  ];

  services.qemuGuest.enable = true;

  system.stateVersion = "25.05";
}
