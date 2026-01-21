{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../docker/jellyfinn/docker-compose.nix
    ../../docker/management/igpu/docker_compose.nix
    ../../docker/plex/docker-compose.nix
    ../../docker/tdarr/igp/docker-compose.nix
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
    containers = {
      enable = true;
      autoUpdate.enable = true;
    };
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
      rebootOnKernelUpdate = true;
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

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    libva-utils
    radeontop
    nvtopPackages.amd
  ]);

  services.qemuGuest.enable = true;

  system.stateVersion = "25.05";
}
