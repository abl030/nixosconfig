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
    ./alert-bridge.nix
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
    ./beancount.nix
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
    ./domain-monitor.nix
    ./forgejo.nix
    ./nfs-watchdog.nix
    ./pfsense-backup-watchdog.nix
    ./syncoid-pfsense.nix
    ./tailscale-share.nix
    ./rtrfm-nowplaying
    ./claude-voice.nix
    ./whisper-server.nix
    ./cullen-dashboard.nix
    ./gwm-archiver.nix
    ./komga.nix
    ./komga-sync.nix
    ./marker-convert.nix
    ./hermes-agent.nix
    ./hermes-operator-deploy.nix
    ./hermes-operator-launcher.nix
  ];
}
