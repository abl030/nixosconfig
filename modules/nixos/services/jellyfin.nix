# Jellyfin + companion services (jellystat analytics, watchstate sync).
# Replaces the LSIO compose stack on igpu — see Phase 3 of #208.
# Lives alongside the production Plex on tower; not a replacement.
#
# Three independently-toggled sub-services under one module:
#   - homelab.services.jellyfin.enable             Jellyfin itself (igpu)
#   - homelab.services.jellyfin.jellystat.enable   Analytics (doc2)
#   - homelab.services.jellyfin.watchstate.enable  Plex<->Jellyfin sync (doc2)
#
# Why bundled: all three are part of the same user-facing feature set and
# historically shipped as one compose stack. See Phase 4 of #208.
#
# Jellyfin layout: a single root-owned `dataRoot` parent contains
#   - data/   (jellyfin --datadir, libraries.db, plugins, metadata cache)
#   - config/ (jellyfin --configdir, XML files)
#   - log/    (jellyfin --logdir)
#   - ts/     (homelab.tailscaleShare.jellyfin state — root-owned sidecars)
# Cache stays local at /var/cache/jellyfin (regenerable, not worth virtiofs).
#
# Why root-owned parent: systemd-tmpfiles refuses ("unsafe path transition")
# to create root-owned children inside a jellyfin-owned parent, so we keep
# dataRoot root-owned 0755 and let services.jellyfin's tmpfiles + the share's
# tmpfiles each create their own jellyfin/root-owned children as siblings.
#
# Hardware acceleration uses upstream services.jellyfin.hardwareAcceleration
# (declarative encoding.xml). forceEncodingConfig = true so NixOS owns the
# encoder settings — webdash changes will be reverted on restart.
#
# Two FQDNs for jellyfin:
#   - `jelly.ablz.au`     LAN, via homelab.localProxy (nginx + ACME on igpu)
#   - `jellyfinn.ablz.au` Inter-tailnet, via homelab.tailscaleShare.jellyfin
#
# Jellystat/watchstate topology on doc2:
#   - OCI containers (rootful podman) with `--user=1000:100` so files on the
#     virtiofs volume end up owned by abl030:users (inspect without sudo).
#   - Jellystat talks to an nspawn PostgreSQL at 192.168.100.15:5432 — see
#     mk-pg-container.nix. Trust auth relies on podman MASQUERADE rewriting
#     the source IP to 192.168.100.14 (host-side veth), which matches
#     pg_hba's trust rule. Verified working 2026-04-16.
#
# See docs/wiki/infrastructure/media-filesystem.md for the mergerfs/virtiofs
# layout that backs `/mnt/fuse/Media/{Movies,TV_Shows,Music}`.
{
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.jellyfin;

  # Nspawn PostgreSQL for jellystat. hostNum=7 (next slot after discogs=6).
  # Trust auth accepts connections from 192.168.100.14 (host side of the
  # veth). The jellystat OCI container on podman0 reaches pg by routing
  # through the host, which MASQUERADEs the source IP to 192.168.100.14.
  #
  # Schema note: jellystat connects with user=jellystat but hardcodes its
  # database name as `jfstat` (upstream default). mk-pg-container creates
  # user+db matching `name`, plus any `extraDatabases`, re-owned to `name`.
  jellystatPgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "jellystat";
    hostNum = 7;
    dataDir = cfg.jellystat.dataDir;
    extraDatabases = ["jfstat"];
  };

  # Container runs as host abl030 (1000:100) so virtiofs files land
  # abl030-owned — matches the "no root-owned state" rule from #208.
  # We pin to uid/gid numbers because containers can't resolve host usernames.
  containerUid = "1000";
  containerGid = "100";
in {
  options.homelab.services.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    dataRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/jellyfin";
      description = ''
        Parent directory holding ALL jellyfin-related state (data, config,
        log, tailscale-share). Created root-owned 0755 so jellyfin-owned
        and root-owned children can coexist as siblings without
        systemd-tmpfiles "unsafe path transition" errors.

        Per .claude/rules/nixos-service-modules.md, set this to
        /mnt/virtio/jellyfin in the host config so service state lives
        on virtiofs (host VM disposable, data survives on prom ZFS).
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

    # ----------------------------------------------------------------
    # jellystat — Jellyfin usage analytics (doc2)
    # ----------------------------------------------------------------
    jellystat = {
      enable = lib.mkEnableOption "Jellystat — Jellyfin usage analytics (OCI)";

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/virtio/jellystat";
        description = ''
          Parent directory for jellystat state. Contains:
            postgres/    nspawn PG data (mk-pg-container managed, 0700 root)
            backup-data/ jellystat's /app/backend/backup-data (abl030 owned)
        '';
      };

      fqdn = lib.mkOption {
        type = lib.types.str;
        default = "jellystat.ablz.au";
        description = "FQDN served by homelab.localProxy.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3010;
        description = ''
          Host-side port. The container always listens on 3000 internally;
          this is what nginx upstream-proxies to. 3010 because 3000 is
          occupied on doc2 (mealie-gotenberg) and 3001 by uptime-kuma.
        '';
      };

      jellyfinUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://${cfg.fqdn}";
        description = ''
          URL jellystat uses to reach its Jellyfin backend. Defaults to
          the parent module's LAN FQDN — works from doc2 because
          jelly.ablz.au resolves to igpu's LAN IP via homelab.localProxy.
        '';
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "docker.io/cyfershepard/jellystat:latest";
        description = "OCI image for jellystat.";
      };
    };

    # ----------------------------------------------------------------
    # watchstate — cross-backend watch-state sync (doc2)
    # ----------------------------------------------------------------
    watchstate = {
      enable = lib.mkEnableOption "watchstate — Plex<->Jellyfin watch-state sync (OCI)";

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/virtio/watchstate";
        description = ''
          Bind-mounted to /config inside the container. Holds all backend
          config, tokens, sync state, caddy certs. Backends (Plex, Jellyfin)
          are configured via the WebUI, not env vars — everything persists here.
        '';
      };

      fqdn = lib.mkOption {
        type = lib.types.str;
        default = "watchstate.ablz.au";
        description = "FQDN served by homelab.localProxy.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8099;
        description = ''
          Host-side port. Container listens on 8080 internally; 8099 on host
          because 8080-8086 are in use on doc2 (immich, stirling-pdf).
        '';
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/arabcoders/watchstate:latest";
        description = "OCI image for watchstate.";
      };
    };
  };

  config = lib.mkMerge [
    # ============================================================
    # Jellyfin itself (igpu)
    # ============================================================
    (lib.mkIf cfg.enable {
      # `mkBefore` pins our parent rule ahead of tailscaleShare's children
      # (which create ${dataRoot}/ts/*). tmpfiles processes rules in file
      # order; without this the children would hit "parent doesn't exist"
      # and silently fail.
      #
      # Pre-create the root-owned `dataRoot` parent so jellyfin-owned
      # (data/config/log) and root-owned (ts) children can coexist without
      # tripping systemd-tmpfiles unsafe-path-transition canonicalization.
      systemd.tmpfiles.rules = lib.mkBefore [
        "d ${cfg.dataRoot} 0755 root root - -"
      ];

      services.jellyfin = {
        enable = true;
        user = "jellyfin";
        group = "jellyfin";
        dataDir = "${cfg.dataRoot}/data";
        configDir = "${cfg.dataRoot}/config";
        logDir = "${cfg.dataRoot}/log";
        # cacheDir stays default /var/cache/jellyfin — regenerable, not on virtiofs

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

      # Give the host admin (hostConfig.user) group membership in `jellyfin`
      # so they can ls/cat data for debugging without sudo. Combined with the
      # tmpfiles mode override and UMask below, everything jellyfin writes
      # lands as jellyfin:jellyfin 0640 / 0750 (group readable).
      users.users.${hostConfig.user}.extraGroups = ["jellyfin"];

      systemd.services.jellyfin.serviceConfig.UMask = lib.mkForce "0027";

      # Upstream creates these all with mode 0700 — override to 0750 so group
      # members (admin) can traverse. File mode is controlled by the service's
      # UMask above.
      systemd.tmpfiles.settings.jellyfinDirs = {
        "${cfg.dataRoot}/data"."d".mode = lib.mkForce "0750";
        "${cfg.dataRoot}/config"."d".mode = lib.mkForce "0750";
        "${cfg.dataRoot}/log"."d".mode = lib.mkForce "0750";
        "/var/cache/jellyfin"."d".mode = lib.mkForce "0750";
      };

      # PublishedServerUrl drives the auto-announce URL clients pick up.
      systemd.services.jellyfin.environment.JELLYFIN_PublishedServerUrl = cfg.publishedServerUrl;

      homelab = {
        # LAN: jelly.ablz.au via igpu's own nginx + ACME.
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
          # Sibling of jellyfin's data/config/log; root-owned 0755 (see header).
          dataDir = "${cfg.dataRoot}/ts";
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
    })

    # ============================================================
    # Jellystat (doc2) — Jellyfin usage analytics with PostgreSQL
    # ============================================================
    (lib.mkIf cfg.jellystat.enable {
      sops.secrets."jellystat/env" = {
        sopsFile = config.homelab.secrets.sopsFile "jellystat.env";
        format = "dotenv";
        mode = "0400";
      };

      # nspawn PostgreSQL. See mk-pg-container header for cascade-stop gotcha.
      containers.jellystat-db = jellystatPgc.containerConfig;

      systemd.tmpfiles.rules = [
        "d ${cfg.jellystat.dataDir} 0755 ${hostConfig.user} users -"
        "d ${cfg.jellystat.dataDir}/backup-data 0755 ${hostConfig.user} users -"
        # mk-pg-container bindmounts ${dataDir}/postgres into the nspawn.
        # 0700 root:root matches the pattern used by cratedigger/immich/etc.
        "d ${cfg.jellystat.dataDir}/postgres 0700 root root -"
      ];

      virtualisation.oci-containers.containers.jellystat = {
        image = cfg.jellystat.image;
        autoStart = true;
        pull = "newer";
        environmentFiles = [config.sops.secrets."jellystat/env".path];
        environment = {
          POSTGRES_USER = "jellystat";
          POSTGRES_IP = jellystatPgc.dbHost;
          POSTGRES_PORT = toString jellystatPgc.dbPort;
          JELLYFIN_URL = cfg.jellystat.jellyfinUrl;
          TZ = "Australia/Perth";
        };
        ports = ["${toString cfg.jellystat.port}:3000"];
        volumes = [
          "${cfg.jellystat.dataDir}/backup-data:/app/backend/backup-data"
        ];
        extraOptions = [
          # Run the container process as abl030:users so volume writes land
          # non-root on the host. See header `containerUid`/`containerGid`.
          "--user=${containerUid}:${containerGid}"
        ];
      };

      # Requires= on the pg container drives systemd cascade-stop semantics;
      # restartTriggers ensures switch-to-configuration re-runs us when the
      # container unit wrapper changes. See mk-pg-container.nix header.
      systemd.services.podman-jellystat = {
        after = ["container@jellystat-db.service"];
        requires = ["container@jellystat-db.service"];
        restartTriggers = [config.systemd.units."container@jellystat-db.service".unit];
      };

      homelab = {
        podman.enable = true;
        podman.containers = [
          {
            unit = "podman-jellystat.service";
            image = cfg.jellystat.image;
          }
        ];

        localProxy.hosts = [
          {
            host = cfg.jellystat.fqdn;
            port = cfg.jellystat.port;
          }
        ];

        monitoring.monitors = [
          {
            name = "Jellystat";
            url = "https://${cfg.jellystat.fqdn}/";
          }
        ];
      };
    })

    # ============================================================
    # watchstate (doc2) — Plex <-> Jellyfin sync, no DB
    # ============================================================
    (lib.mkIf cfg.watchstate.enable {
      systemd.tmpfiles.rules = [
        "d ${cfg.watchstate.dataDir} 0755 ${hostConfig.user} users -"
      ];

      virtualisation.oci-containers.containers.watchstate = {
        image = cfg.watchstate.image;
        autoStart = true;
        pull = "newer";
        environment = {
          # Upstream reads these at entrypoint to chown /config and drop privs.
          WS_UID = containerUid;
          WS_GID = containerGid;
          TZ = "Australia/Perth";
        };
        ports = ["${toString cfg.watchstate.port}:8080"];
        volumes = [
          "${cfg.watchstate.dataDir}:/config"
        ];
      };

      homelab = {
        podman.enable = true;
        podman.containers = [
          {
            unit = "podman-watchstate.service";
            image = cfg.watchstate.image;
          }
        ];

        localProxy.hosts = [
          {
            host = cfg.watchstate.fqdn;
            port = cfg.watchstate.port;
          }
        ];

        monitoring.monitors = [
          {
            name = "watchstate";
            url = "https://${cfg.watchstate.fqdn}/";
          }
        ];
      };
    })
  ];
}
