{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.audiobookshelf;
in {
  options.homelab.services.audiobookshelf = {
    enable = lib.mkEnableOption "Audiobookshelf audiobook/podcast server (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/audiobookshelf";
      description = "Directory where Audiobookshelf stores its data (database, metadata, settings).";
    };

    # #257: ABS library folders are configured in the web UI (stored in its
    # sqlite DB), but the unit's mount sandbox is static — so the set of NFS
    # media dirs ABS may read/write has to be declared here too. These are
    # bound rw (ABS embeds metadata into audio files). If you add a library
    # folder in the UI under a path NOT listed here, ABS won't be able to see
    # it (blank /mnt masks everything else). Keep this in sync with the UI.
    libraryDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["/mnt/data/Media/Books/Audiobooks"];
      description = "NFS/media library folders ABS serves; bound into the unit's sandboxed /mnt. Must match the library folders configured in the ABS UI.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ABS binds the podman bridge gateway (10.88.0.1, see host below), which may
    # not be up when the unit starts at boot. Allow binding a not-yet-present
    # local address; once podman0 appears, traffic flows.
    boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = lib.mkDefault 1;

    services.audiobookshelf = {
      enable = true;
      port = 13378;
      # Bind ONLY the podman bridge gateway (host.docker.internal = 10.88.0.1),
      # not loopback and not 0.0.0.0. The tailnet-share caddy sidecar runs in the
      # ts netns and reaches ABS via host.docker.internal — it CANNOT use
      # 127.0.0.1 (that's the container's own loopback), so a loopback-only bind
      # silently 502s the share. Binding the bridge gateway means ABS listens on
      # NO routable interface (not tailscale0, not the LAN) — the only ways in
      # are nginx (audiobook.ablz.au, dialed at 10.88.0.1 via localProxy
      # upstreamHost below) and the dedicated audiobooks share node. This is the
      # per-service complement to netfilterMode=off: defence-in-depth, the bare
      # port simply does not exist on any routable IP. ip_nonlocal_bind (below)
      # lets ABS bind 10.88.0.1 even before podman0 is up at boot.
      host = "10.88.0.1";
    };

    # Add audiobookshelf user to users group for NFS media access
    # (audiobook dirs are gid=users with setgid)
    users.users.audiobookshelf.extraGroups = ["users"];

    systemd = {
      services = {
        # Override upstream service to use custom data dir (virtiofs).
        # #257: ABS shipped no sandboxing and inherited the host's entire
        # /mnt/* tree RW — including /mnt/backup/pfsense, /mnt/appdata,
        # /mnt/mum. Blank /mnt and bind back only its virtiofs state dir plus
        # the declared NFS library folders (rw — ABS embeds metadata into
        # audio files). RequiresMountsFor orders the fail-loud binds after
        # their mounts. (ProtectSystem=strict deliberately NOT added here —
        # the Node app's full set of writable paths isn't pinned down; the
        # /mnt narrowing is the blast-radius win that #257 targets.)
        audiobookshelf = {
          unitConfig.RequiresMountsFor = [cfg.dataDir] ++ cfg.libraryDirs;
          serviceConfig = {
            WorkingDirectory = lib.mkForce cfg.dataDir;
            StateDirectory = lib.mkForce "";
            TemporaryFileSystem = "/mnt";
            BindPaths = [cfg.dataDir] ++ cfg.libraryDirs;
          };
        };

        # Weekly cleanup of embed-metadata backups (originals stashed by ABS
        # when the API embed endpoint writes tags into audio files)
        audiobookshelf-cache-cleanup = {
          description = "Purge Audiobookshelf embed-metadata backup cache";
          unitConfig.RequiresMountsFor = [cfg.dataDir];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe' config.systemd.package "rm"} -rf ${cfg.dataDir}/metadata/cache/items";
            User = "audiobookshelf";
            TemporaryFileSystem = "/mnt";
            BindPaths = [cfg.dataDir];
          };
        };
      };

      timers.audiobookshelf-cache-cleanup = {
        description = "Weekly Audiobookshelf cache cleanup";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "audiobook.ablz.au";
          port = 13378;
          # ABS binds the podman bridge gateway, not loopback (see host above).
          upstreamHost = "10.88.0.1";
          websocket = true;
        }
      ];

      tailscaleShare.audiobookshelf = {
        enable = true;
        fqdn = "audiobooks.ablz.au";
        upstream = "http://host.docker.internal:13378";
        dataDir = "/mnt/virtio/tailscale-share/audiobookshelf";
        hostname = "audiobookshelf";
        authKeySecret = null;
        firewallPorts = [13378];
        monitorName = "Audiobookshelf (Tailnet)";
      };

      monitoring.monitors = [
        {
          name = "Audiobookshelf (LAN)";
          url = "https://audiobook.ablz.au/";
        }
      ];

      # See #253 audit. SKIPPED. The 30-day audit showed only:
      #   - "Cannot validate socket - invalid token" (benign auth/idle)
      #   - GoogleBooks 429 rate-limits (upstream)
      #   - per-asset [AudioFileScanner] failures on malformed media
      # None of these represent service-broken state — they're per-asset
      # or external-API noise. Real outages flow through the Kuma HTTP
      # monitor above. The one entry is the #257 fail-loud bind of the
      # virtiofs state dir + NFS library folders.
      monitoring.errorPatterns = [
        {
          name = "Audiobookshelf namespace failure";
          unit = "audiobookshelf.service";
          pattern = "(?i)Failed at step NAMESPACE";
          severity = "critical";
          summary = "audiobookshelf cannot bind its state/library dirs — server is down";
          description = "A BindPaths source (virtiofs dataDir or an NFS library folder) is missing or stale — check mnt-virtio.mount / mnt-data.mount on doc2.";
          threshold = 0;
        }
      ];
    };
  };
}
