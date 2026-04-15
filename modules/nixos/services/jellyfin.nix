# Jellyfin media server (native NixOS module).
# Replaces the LSIO compose stack on igpu — see Phase 3 of #208.
# Lives alongside the production Plex on tower; not a replacement.
#
# Layout decisions:
# - Use nixpkgs default split: --datadir /var/lib/jellyfin, --configdir
#   /var/lib/jellyfin/config. (Originally tried configDir == dataDir to match
#   LSIO's flat /config layout but the upstream module's tmpfiles.settings
#   collides on duplicate dynamic-attr keys when both equal the same path.)
#   Migration: rsync data/metadata/plugins/root → dataDir, XML files →
#   configDir/ — see Phase 3 of #208 for the exact commands.
# - Hardware acceleration uses upstream services.jellyfin.hardwareAcceleration
#   (declarative encoding.xml). forceEncodingConfig = true so NixOS owns
#   the encoder settings — webdash changes will be reverted on restart.
# - Two FQDNs: `jelly.ablz.au` (LAN via homelab.localProxy + nginx ACME),
#   `jellyfinn.ablz.au` (inter-tailnet via homelab.tailscaleShare).
#
# See docs/wiki/infrastructure/media-filesystem.md for the mergerfs/virtiofs
# layout that backs `/mnt/fuse/Media/{Movies,TV_Shows,Music}`.
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.jellyfin;
in {
  options.homelab.services.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/jellyfin";
      description = ''
        --datadir for jellyfin (libraries.db, plugins, metadata cache).
        --configdir defaults to dataDir/config (XML files); cache and log
        use nixpkgs defaults (/var/cache/jellyfin, dataDir/log).
      '';
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "jelly.ablz.au";
      description = "LAN FQDN served by homelab.localProxy (nginx + ACME).";
    };

    tailscaleFqdn = lib.mkOption {
      type = lib.types.str;
      default = "jellyfinn.ablz.au";
      description = "Inter-tailnet FQDN served by homelab.tailscaleShare.jellyfin.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8096;
      description = "HTTP port jellyfin listens on.";
    };

    publishedServerUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${cfg.fqdn}";
      description = ''
        Equivalent of the LSIO env var JELLYFIN_PublishedServerUrl —
        the URL jellyfin announces to its clients via auto-discovery.
      '';
    };

    hardwareAcceleration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable VAAPI hardware transcoding via /dev/dri/renderD128.";
    };

    nfsWatchdogPath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/fuse/Media/TV_Shows";
      description = ''
        Path the homelab.nfsWatchdog timer probes; if stale, jellyfin restarts.
        Defaults to TV_Shows because its underlying media branch is tower NFS,
        which is the realistic failure mode.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      user = "jellyfin";
      group = "jellyfin";
      dataDir = cfg.dataDir;
      # Open 8096 + 8920 + 7359/udp + 1900/udp on all interfaces for
      # LAN clients (auto-discovery, DLNA) and the LAN nginx upstream.
      openFirewall = true;

      hardwareAcceleration = lib.mkIf cfg.hardwareAcceleration {
        enable = true;
        type = "vaapi";
        device = "/dev/dri/renderD128";
      };

      # NixOS becomes the source of truth for encoding.xml. Web dashboard
      # changes to encoder settings will be overwritten on next restart.
      forceEncodingConfig = lib.mkIf cfg.hardwareAcceleration true;

      transcoding = lib.mkIf cfg.hardwareAcceleration {
        enableHardwareEncoding = true;
        # AMD RDNA3 (Granite Ridge iGPU) supports HEVC + AV1 hw encode.
        hardwareEncodingCodecs = {
          hevc = true;
          av1 = true;
        };
        hardwareDecodingCodecs = {
          h264 = true;
          hevc = true;
          hevc10bit = true;
          vp9 = true;
          av1 = true;
        };
      };
    };

    # /dev/dri/renderD128 is mode 0660 root:render — jellyfin needs `render`.
    # `video` covers card1 if anything ever asks for it.
    users.users.jellyfin.extraGroups = ["render" "video"];

    # PublishedServerUrl drives the auto-announce URL clients pick up.
    systemd.services.jellyfin.environment.JELLYFIN_PublishedServerUrl = cfg.publishedServerUrl;

    homelab = {
      # LAN: jelly.ablz.au → 192.168.1.33:8096 via igpu's own nginx + ACME.
      localProxy.hosts = [
        {
          host = cfg.fqdn;
          port = cfg.port;
          websocket = true;
        }
      ];

      # Inter-tailnet: jellyfinn.ablz.au via dedicated tailscale node + caddy.
      # Reuses the sops auth key at secrets/hosts/igpu/jellyfin-tailscale-authkey.env.
      tailscaleShare.jellyfin = {
        enable = true;
        fqdn = cfg.tailscaleFqdn;
        # NEVER 127.0.0.1 — caddy shares the ts container's net namespace;
        # 127.0.0.1 there is the container's loopback, not the host.
        upstream = "http://host.docker.internal:${toString cfg.port}";
        dataDir = "${cfg.dataDir}/ts";
        hostname = "jellyfin";
        firewallPorts = [cfg.port];
      };

      # Tower NFS provides the Movies/TV_Shows media branches; if it goes
      # stale, jellyfin's library scans deadlock. Watchdog restarts the
      # service after a stale-mount detection.
      nfsWatchdog.jellyfin.path = cfg.nfsWatchdogPath;

      monitoring.monitors = [
        {
          name = "Jellyfin (LAN)";
          url = "https://${cfg.fqdn}/System/Info/Public";
        }
        {
          name = "Jellyfin (Tailnet)";
          url = "https://${cfg.tailscaleFqdn}/System/Info/Public";
        }
      ];
    };
  };
}
