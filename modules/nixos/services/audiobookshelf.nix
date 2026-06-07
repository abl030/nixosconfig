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
    services.audiobookshelf = {
      enable = true;
      port = 13378;
      host = "0.0.0.0";
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
