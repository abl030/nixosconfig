{...}: {
  # Acts as an index so `../../modules/nixos` works.
  imports = [
    ./tailscale # Auto-resolves to ./tailscale/default.nix
    ./ssh # Auto-resolves to ./ssh/default.nix
    ./mounts # Auto-resolves to ./mounts/default.nix
    ./gpu # Auto-resolves to ./gpu/default.nix
    ./display/hyprland.nix
    ./display/wayvnc.nix
    ./system/storage.nix
    ./display/sunshine.nix
    ./rdp-inhibitor.nix
    ./nginx.nix
    ./local_proxy.nix
    ./monitoring_sync.nix
    ./gotify.nix
    ./loki.nix
    ./loki-server.nix
    ./alerting.nix
    ./prometheus.nix
    ./mcp.nix
    ./mdns-reflector.nix
    ./framework
    ./syncthing
    ./immich.nix
    ./gotify-server.nix
    ./tautulli.nix
    ./audiobookshelf.nix
    ./atuin.nix
    ./lidarr.nix
    ./slskd.nix
    ./cratedigger.nix
    ./discogs.nix
    ./paperless.nix
    ./mealie.nix
    ./stirlingpdf.nix
    ./webdav.nix
    ./smokeping.nix
    ./uptime-kuma.nix
    ./jdownloader2.nix
    ./tdarr-node.nix
    ./jellyfin.nix
    ./netboot.nix
    ./overseerr.nix
    ./youtarr.nix
    ./musicbrainz.nix
    ./kopia.nix
    ./meelo.nix
    ./domain-monitor.nix
    ./nfs-watchdog.nix
    ./tailscale-share.nix
    ./rtrfm-nowplaying
  ];
}
