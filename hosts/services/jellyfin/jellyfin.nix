{ config, pkgs, lib, ... }:

{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
    dataDir = "/mnt/docker/jellyfin";
    cacheDir = "/mnt/docker/jellyfin/cache";
    configDir = "/mnt/docker/jellyfin/config";
    logDir = "/mnt/docker/jellyfin/log";
  };
}
