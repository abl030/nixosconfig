{
  config,
  hostConfig,
  lib,
  ...
}: let
  cfg = config.homelab.containers;
  stackModules = {
    atuin = ../../../docker/atuin/docker-compose.nix;
    audiobookshelf = ../../../docker/audiobookshelf/docker-compose.nix;
    domain-monitor = ../../../docker/domain-monitor/docker-compose.nix;
    immich = ../../../docker/immich/docker-compose.nix;
    invoices = ../../../docker/invoices/docker-compose.nix;
    jdownloader2 = ../../../docker/jdownloader2/docker-compose.nix;
    jellyfin = ../../../docker/jellyfinn/docker-compose.nix;
    kopia = ../../../docker/kopia/docker-compose.nix;
    mealie = ../../../docker/mealie/docker-compose.nix;
    music = ../../../docker/music/docker-compose.nix;
    netboot = ../../../docker/netboot/docker-compose.nix;
    paperless = ../../../docker/paperless/docker-compose.nix;
    plex = ../../../docker/plex/docker-compose.nix;
    smokeping = ../../../docker/smokeping/docker-compose.nix;
    stirlingpdf = ../../../docker/StirlingPDF/docker-compose.nix;
    tautulli = ../../../docker/tautulli/docker-compose.nix;
    tdarr-igp = ../../../docker/tdarr/igp/docker-compose.nix;
    uptime-kuma = ../../../docker/uptime-kuma/docker-compose.nix;
    webdav = ../../../docker/WebDav/docker-compose.nix;
    youtarr = ../../../docker/youtarr/docker-compose.nix;

    management = ../../../docker/management/docker-compose.nix;
    igpu-management = ../../../docker/management/igpu/docker_compose.nix;
    epi-management = ../../../docker/management/epi_management/docker_compose.nix;
    tailscale-caddy = ../../../docker/tailscale/caddy/docker-compose.nix;
  };
  enabledStacks = hostConfig.containerStacks or [];
  missingStacks = lib.filter (name: !(builtins.hasAttr name stackModules)) enabledStacks;
in {
  imports = map (name: stackModules.${name}) enabledStacks;

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = missingStacks == [];
        message = "Unknown container stacks: ${lib.concatStringsSep ", " missingStacks}";
      }
      {
        assertion = enabledStacks == [] || cfg.enable;
        message = "containerStacks is set but homelab.containers.enable is false.";
      }
    ];
  };
}
