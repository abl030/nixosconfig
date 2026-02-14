{
  config,
  hostConfig,
  lib,
  ...
}: let
  cfg = config.homelab.containers;
  stackModules = {
    atuin = ../../../../stacks/atuin/docker-compose.nix;
    audiobookshelf = ../../../../stacks/audiobookshelf/docker-compose.nix;
    domain-monitor = ../../../../stacks/domain-monitor/docker-compose.nix;
    immich = ../../../../stacks/immich/docker-compose.nix;
    invoices = ../../../../stacks/invoices/docker-compose.nix;
    jdownloader2 = ../../../../stacks/jdownloader2/docker-compose.nix;
    jellyfin = ../../../../stacks/jellyfinn/docker-compose.nix;
    kopia = ../../../../stacks/kopia/docker-compose.nix;
    loki = ../../../../stacks/loki/docker-compose.nix;
    mealie = ../../../../stacks/mealie/docker-compose.nix;
    music = ../../../../stacks/music/docker-compose.nix;
    netboot = ../../../../stacks/netboot/docker-compose.nix;
    openobserve = ../../../../stacks/openobserve/docker-compose.nix;
    paperless = ../../../../stacks/paperless/docker-compose.nix;
    plex = ../../../../stacks/plex/docker-compose.nix;
    restart-probe = ../../../../stacks/restart-probe/docker-compose.nix;
    restart-probe-b = ../../../../stacks/restart-probe-b/docker-compose.nix;
    smokeping = ../../../../stacks/smokeping/docker-compose.nix;
    stirlingpdf = ../../../../stacks/StirlingPDF/docker-compose.nix;
    tautulli = ../../../../stacks/tautulli/docker-compose.nix;
    tdarr-igp = ../../../../stacks/tdarr/igp/docker-compose.nix;
    uptime-kuma = ../../../../stacks/uptime-kuma/docker-compose.nix;
    webdav = ../../../../stacks/WebDav/docker-compose.nix;
    youtarr = ../../../../stacks/youtarr/docker-compose.nix;

    management = ../../../../stacks/management/docker-compose.nix;
    igpu-management = ../../../../stacks/management/igpu/docker_compose.nix;
    epi-management = ../../../../stacks/management/epi_management/docker_compose.nix;
    tailscale-caddy = ../../../../stacks/tailscale/caddy/docker-compose.nix;
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
