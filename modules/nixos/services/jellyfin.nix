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
#   - ts/     (homelab.tailscaleShare.jellyfin state — root-owned TS state,
#              caddy state owned by tailscale-share-caddy)
# Cache stays local at /var/cache/jellyfin (regenerable, not worth virtiofs).
#
# Why root-owned parent: systemd-tmpfiles refuses ("unsafe path transition")
# to create mixed-owner children inside a jellyfin-owned parent, so we keep
# dataRoot root-owned 0755 and let services.jellyfin's tmpfiles + the share's
# tmpfiles create their own jellyfin/root/caddy-owned children as siblings.
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
#   - Jellystat talks to an nspawn PostgreSQL at 10.20.0.15:5432 — see
#     mk-pg-container.nix. Trust auth relies on podman MASQUERADE rewriting
#     the source IP to 10.20.0.14 (host-side veth), which matches
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
  # Connections from 10.20.0.14 (host side of veth) are scram-sha-256
  # authed since #232 — trust auth was retired after we found any OCI
  # container on podman0 could pivot to superuser fleet-wide. PG password
  # lives in the sops-managed jellystat-pgpass.env (alongside the existing
  # jellystat.env), bindmounted into the nspawn for ALTER USER and merged
  # into the OCI container's environmentFiles for the consumer side.
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
    passwordFile = "/run/secrets/jellystat-pgpass";
  };

  # Container runs as host abl030 (1000:100) so virtiofs files land
  # Dedicated per-service UID (forgejo#2 / #232). Containers must NOT run as host
  # UID 1000 (abl030): that user has passwordless sudo on doc2, so a popped +
  # escaped container would inherit it (the lateral-pivot vector). jellystat is a
  # Node app that honours `--user` directly, so it gets a clean dedicated UID
  # like youtarr(2009)/tdarr(2010). GID stays 100 (users) for group-readable
  # writes; numeric because containers can't resolve host usernames.
  # (watchstate + netboot run an image-internal UID-1000 user that doesn't
  # relocate under cap-drop — those need userns remapping, forgejo#2 Phase 1b.)
  jellystatUid = 2014;
in {
  options.homelab.services.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    dataRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/jellyfin";
      description = ''
        Parent directory holding ALL jellyfin-related state (data, config,
        log, tailscale-share). Created root-owned 0755 so jellyfin-owned,
        root-owned, and numeric caddy-owned children can coexist as siblings
        without systemd-tmpfiles "unsafe path transition" errors.

        Per docs/wiki/nixos-service-modules.md, set this to
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
      # (data/config/log), root-owned, and caddy-owned (ts) children can
      # coexist without
      # tripping systemd-tmpfiles unsafe-path-transition canonicalization.
      systemd = {
        tmpfiles = {
          rules = lib.mkBefore [
            "d ${cfg.dataRoot} 0755 root root - -"
          ];

          # Upstream creates these all with mode 0700 — override to 0750 so group
          # members (admin) can traverse. File mode is controlled by the service's
          # UMask below.
          settings.jellyfinDirs = {
            "${cfg.dataRoot}/data"."d".mode = lib.mkForce "0750";
            "${cfg.dataRoot}/config"."d".mode = lib.mkForce "0750";
            "${cfg.dataRoot}/log"."d".mode = lib.mkForce "0750";
            "/var/cache/jellyfin"."d".mode = lib.mkForce "0750";
          };
        };

        services.jellyfin = {
          serviceConfig = {
            UMask = lib.mkForce "0027";

            # Trickplay "save with media" writes .trickplay dirs onto the
            # /mnt/fuse mergerfs union, which presents everything as
            # abl030:users 0775 — jellyfin needs gid 100 (users) for group
            # write, else every save fails UnauthorizedAccessException and the
            # task re-churns the library forever (the July 2026 "14% CPU
            # floor"). Unit-level rather than users.*.extraGroups so a switch
            # restarts jellyfin and the running process picks the group up;
            # systemd extends (not replaces) the user-db groups, so
            # render/video from extraGroups below keep working.
            SupplementaryGroups = ["users"];
          };

          # PublishedServerUrl drives the auto-announce URL clients pick up.
          environment.JELLYFIN_PublishedServerUrl = cfg.publishedServerUrl;
        };
      };

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

      homelab = {
        # LAN: jelly.ablz.au via igpu's own nginx + ACME.
        localProxy.hosts = [
          {
            host = cfg.fqdn;
            inherit (cfg) port;
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
          # Sibling of jellyfin's data/config/log; mixed owner subdirs (see header).
          dataDir = "${cfg.dataRoot}/ts";
          hostname = "jellyfin";
          firewallPorts = [cfg.port];
          monitorName = "Jellyfin (Tailnet)";
          monitorPath = "/System/Info/Public";
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
        ];

        # See #253 audit. Jellyfin proper produced no actionable error
        # logs in the 30-day window. Real outages flow through the
        # Kuma HTTP monitor on /System/Info/Public above. (caddy/ts
        # sidecars have their own patterns in tailscale-share.nix.)
        monitoring.errorPatterns = [];
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

      # PG password — separate file from jellystat/env so DB credentials stay
      # narrow without exposing other jellystat secrets (JWT_SECRET etc.).
      sops.secrets."jellystat-pgpass" = {
        sopsFile = config.homelab.secrets.sopsFile "jellystat-pgpass.env";
        format = "dotenv";
        mode = "0400";
      };

      # nspawn PostgreSQL. See mk-pg-container header for cascade-stop gotcha.
      containers.jellystat-db = jellystatPgc.containerConfig;

      # Dedicated UID for the analytics container (see header). isSystemUser so
      # it can't log in; group=users keeps volume writes group-readable.
      users.users.jellystat = {
        isSystemUser = true;
        uid = jellystatUid;
        group = "users";
        description = "jellystat analytics container runtime user";
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.jellystat.dataDir} 0755 ${hostConfig.user} users -"
        # backup-data is the only path the container writes; own it as jellystat
        # and recursively re-own existing backups (migration off abl030/1000).
        "d ${cfg.jellystat.dataDir}/backup-data 0750 jellystat users -"
        "Z ${cfg.jellystat.dataDir}/backup-data - jellystat users -"
        # mk-pg-container bindmounts ${dataDir}/postgres into the nspawn.
        # 0700 root:root matches the pattern used by cratedigger/immich/etc.
        # NOTE: never recursively chown the parent dataDir — it would hit this.
        "d ${cfg.jellystat.dataDir}/postgres 0700 root root -"
      ];

      virtualisation.oci-containers.containers.jellystat = {
        image = cfg.jellystat.image;
        autoStart = true;
        pull = "newer";
        # Order matters: pgpass loads after jellystat/env so the canonical
        # POSTGRES_PASSWORD takes effect even if a stale value remains in
        # jellystat/env.
        environmentFiles = [
          config.sops.secrets."jellystat/env".path
          config.sops.secrets."jellystat-pgpass".path
        ];
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
        # Node analytics app, runs as --user on an unprivileged port — needs no
        # Linux capabilities. cap-drop=all + no-new-privileges via hardenOptions.
        extraOptions =
          config.homelab.podman.hardenOptions
          ++ [
            # Dedicated non-abl030 UID (see header) so a popped container can't be
            # the passwordless-sudo user; :100 keeps writes group-users-readable.
            "--user=${toString jellystatUid}:100"
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

        # No errorPattern for Jellystat DB: if the DB is truly down the app
        # crash-loops, which Uptime Kuma catches via its HTTP monitor. Transient
        # virtiofs blips that self-heal in seconds should not page.
        # monitoring.errorPatterns = [
        #   {
        #     name = "Jellystat DB unreachable";
        #     unit = "podman-jellystat.service";
        #     pattern = "(?i)Postgres DB Connection refused|FATAL";
        #     severity = "warning";
        #     summary = "jellystat cannot reach its PostgreSQL DB";
        #     forDuration = "10m";
        #   }
        # ];
      };
    })

    # ============================================================
    # watchstate (doc2) — Plex <-> Jellyfin sync, no DB
    # ============================================================
    (lib.mkIf cfg.watchstate.enable {
      # forgejo#2 Phase 1b: watchstate's image hardcodes a UID-1000 "user" which,
      # under rootful podman, IS host abl030 — and its WS_UID switch can't
      # relocate it under cap-drop=all (it crash-loops, see git history). So we
      # userns-remap the whole container instead (--uidmap/--gidmap below):
      # container UID 1000 → host 201000, never abl030. WS_UID stays 1000 (the
      # image's happy default — no in-container switch needed). The `:U` volume
      # flag migrates the existing abl030-owned /config into the mapped range.
      systemd.tmpfiles.rules = [
        # Own the dataDir as the container's HOST-MAPPED run user (userns base
        # 200000 + WS_UID 1000 = 201000), NOT root:root. The `:U` volume flag
        # only corrects ownership on container START — but systemd-tmpfiles
        # re-runs on every boot/switch and, with a `root root` rule, resets this
        # dir to host-root UNDER the already-running container. Inside the userns
        # host-0 is the unmapped `nobody`, so the app abruptly loses write to
        # /config and 503s until the next container restart re-runs `:U`. That is
        # exactly the 2026-06-23 outage (an unclean prom reboot left it reset).
        # Owning the dir as the mapped UID makes every tmpfiles re-run a no-op
        # and survives reboots. Keep 201000 in sync with the --uidmap base
        # (200000) + WS_UID (1000) below.
        "d ${cfg.watchstate.dataDir} 0755 201000 201000 -"
      ];

      virtualisation.oci-containers.containers.watchstate = {
        image = cfg.watchstate.image;
        autoStart = true;
        pull = "newer";
        environment = {
          # Upstream reads these at entrypoint to chown /config and drop privs.
          # Stays 1000 (the image's built-in user) — see the Phase-1b NOTE above;
          # switching it off 1000 needs userns, not this env, under cap-drop.
          WS_UID = "1000";
          WS_GID = "100";
          TZ = "Australia/Perth";
        };
        ports = ["${toString cfg.watchstate.port}:8080"];
        volumes = [
          # :U chowns /config into the userns range on start (migrates off abl030).
          "${cfg.watchstate.dataDir}:/config:U"
        ];
        # Upstream entrypoint runs as root, chowns /config, then drops to
        # WS_UID/WS_GID — needs the file-ownership + setuid/setgid drop caps
        # (which apply within the userns); the unprivileged :8080 bind needs none.
        extraOptions =
          config.homelab.podman.hardenOptions
          ++ [
            # userns remap (forgejo#2): container UID 1000 → host 201000, off
            # abl030. Specifying uid/gid maps implies a private user namespace.
            "--uidmap=0:200000:65536"
            "--gidmap=0:200000:65536"
            "--cap-add=CHOWN"
            "--cap-add=SETUID"
            "--cap-add=SETGID"
            "--cap-add=DAC_OVERRIDE"
            "--cap-add=FOWNER"
            "--cap-add=KILL"
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

        # See #253 audit. SKIPPED — all watchstate ERROR lines in the
        # 30-day window are per-webhook 400s from Plex sending
        # unsupported content types (album/artist). Not a
        # service-broken signal; the Kuma HTTP monitor covers real
        # outages.
        monitoring.errorPatterns = [];
      };
    })
  ];
}
