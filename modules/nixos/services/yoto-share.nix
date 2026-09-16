# Yoto share — source-library browsing with on-demand card ZIP downloads.
# The app reuses yoto-prep's splitting without keeping tracks or ZIPs on NFS.
#
# See docs/wiki/services/yoto-share.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.yotoShare;
  serverPython = pkgs.python3.withPackages (ps: [ps.flask ps.gunicorn]);
  serverSource = builtins.path {
    path = ./yoto-share;
    name = "yoto-share-source";
  };

  yotoPrepScript = pkgs.writers.writePython3Bin "yoto-prep" {
    libraries = [];
    # The repo formats Python at ~100 cols and uses implicit string
    # concatenation in f-strings; flake8's 79-col default is not the house
    # style.
    flakeIgnore = ["E501" "W503" "W504" "E226"];
  } (builtins.readFile ./yoto-share/yoto-prep.py);

  # ffmpeg/ffprobe do the demux, cut and artwork work. Wrap rather than
  # hardcode store paths so the script stays runnable straight from a checkout
  # during development.
  yoto-prep = pkgs.runCommand "yoto-prep" {nativeBuildInputs = [pkgs.makeWrapper];} ''
    mkdir -p $out/bin
    makeWrapper ${yotoPrepScript}/bin/yoto-prep $out/bin/yoto-prep \
      --prefix PATH : ${lib.makeBinPath [pkgs.ffmpeg]} \
      --set-default YOTO_LIBRARY ${lib.escapeShellArg cfg.libraryDir} \
      --set-default YOTO_OUT ${lib.escapeShellArg cfg.booksDir}
  '';
in {
  options.homelab.services.yotoShare = {
    enable = lib.mkEnableOption "Yoto MYO audiobook catalogue and on-demand card downloads";

    port = lib.mkOption {
      type = lib.types.port;
      default = 13381;
      description = "Private podman bridge port for the card download service.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "yoto.ablz.au";
      description = "FQDN the share is published at on its own tailscale node.";
    };

    shareDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Yoto";
      description = ''
        Existing publication tree containing Music and any manually prepared
        books. The web catalogue reads audiobooks from libraryDir instead.
      '';
    };

    booksDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.shareDir}/Books";
      defaultText = lib.literalExpression ''"''${config.homelab.services.yotoShare.shareDir}/Books"'';
      description = "Prepared Yoto audiobook output beneath the published top-level tree.";
    };

    libraryDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Books/Audiobooks";
      description = "Source audiobooks visible to every peer with access to the Yoto share.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/tailscale-share/yoto";
      description = "Persistent tailscale + caddy state for the share node.";
    };

    # A browser can only ever fetch one file per tap, so the HTTPS listing
    # forces a choice between "unzip a card" and "tap 15 tracks". WebDAV
    # removes the dilemma: Android file managers (Solid Explorer, Cx, Material
    # Files) mount it natively, so the peer selects a whole card and copies it
    # straight into Downloads — no archive step, no per-file tapping.
    # ADDITIVE: its own node and FQDN; yoto.ablz.au keeps working unchanged.
    webdav = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Expose the same prepared tree over read-only WebDAV on its own node.";
      };

      fqdn = lib.mkOption {
        type = lib.types.str;
        default = "yotodav.ablz.au";
        description = "FQDN for the WebDAV endpoint (separate node from the browse share).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 13380;
        description = "Local port rclone's WebDAV server listens on.";
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/virtio/tailscale-share/yotodav";
        description = "Persistent tailscale + caddy state for the WebDAV share node.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [yoto-prep];

    systemd.services.yoto-library = {
      description = "Yoto audiobook catalogue and streaming card downloads";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      unitConfig.RequiresMountsFor = [cfg.libraryDir cfg.shareDir];
      path = [pkgs.ffmpeg];
      environment = {
        YOTO_LIBRARY = cfg.libraryDir;
        YOTO_SHARE = cfg.shareDir;
        TMPDIR = "/tmp";
        PYTHONDONTWRITEBYTECODE = "1";
      };
      serviceConfig = {
        ExecStart = "${serverPython}/bin/gunicorn --chdir ${serverSource} --bind 10.88.0.1:${toString cfg.port} --workers 1 --threads 8 --timeout 240 --access-logfile - server:app";
        Restart = "on-failure";
        RestartSec = 5;
        DynamicUser = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
        # Source and publication mounts are read-only; no ABS credentials or
        # other /mnt trees are visible. Only bridge clients can reach the app.
        TemporaryFileSystem = ["/mnt" "/tmp:size=512M,mode=1777" "/var/tmp:size=1M,mode=1777"];
        BindReadOnlyPaths = [cfg.libraryDir cfg.shareDir];
        IPAddressDeny = "any";
        IPAddressAllow = ["localhost" "10.88.0.0/16"];
        # Two downloads, one <=100 MB track each, no persistent ZIP cache.
        LimitFSIZE = "110M";
        MemoryMax = "1G";
        TasksMax = 128;
        CPUQuota = "200%";
        UMask = "0077";
      };
    };

    # rclone binds the podman bridge gateway, which may not exist yet at boot.
    # Same rationale and same value as audiobookshelf.nix — but two mkDefaults
    # of one sysctl tie rather than merge, so take a defined-winner priority
    # instead. Declared here (not inherited from ABS) so yotoShare stands up on
    # a host that does not run Audiobookshelf.
    boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = lib.mkOverride 900 1;

    # Read-only WebDAV view of the prepared tree.
    #
    # Binds ONLY the podman bridge gateway (host.docker.internal = 10.88.0.1),
    # so the port exists on no routable interface — not tailscale0, not the
    # LAN. The only way in is the yotodav caddy sidecar, which reaches it over
    # podman0. Same defence-in-depth as audiobookshelf.nix.
    #
    # --read-only is load-bearing: the peer must never be able to write into,
    # rename, or delete anything under the media tree. WebDAV is a read/write
    # protocol by default and file managers WILL offer delete if the server
    # allows it.
    systemd.services.yoto-webdav = lib.mkIf cfg.webdav.enable {
      description = "Read-only WebDAV view of the Yoto share";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      unitConfig.RequiresMountsFor = [cfg.shareDir];
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe pkgs.rclone)
          "serve webdav"
          (lib.escapeShellArg cfg.shareDir)
          "--addr 10.88.0.1:${toString cfg.webdav.port}"
          "--read-only"
        ];
        Restart = "on-failure";
        RestartSec = 5;

        # Least privilege (#232): a transient user with no home, no capabilities
        # and no write access to anything. The media files are world-readable on
        # NFS, so no group membership is needed to serve them.
        DynamicUser = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
        # Blank /mnt and bind back ONLY the published tree, read-only — the
        # unit can see the Yoto folder and nothing else under /mnt.
        TemporaryFileSystem = "/mnt";
        BindReadOnlyPaths = [cfg.shareDir];
      };
    };

    homelab = {
      tailscaleShare.yoto = {
        enable = true;
        inherit (cfg) fqdn dataDir;
        upstream = "http://host.docker.internal:${toString cfg.port}";
        firewallPorts = [cfg.port];
        hostname = "yoto";
        # Same access as the audiobookshelf/overseer/jellyfin shares. The
        # default-deny tailnet grants tag:share inbound 443 from tag:client,
        # tag:server (Kuma health checks) and autogroup:shared (inter-tailnet
        # peers) — so no bespoke ACL rule is needed, and share->fleet egress
        # stays denied. Untagged, only doc1 could reach it.
        tags = ["tag:share"];
        # First run logs a login URL in `podman logs ts-yoto`; state then
        # persists under dataDir/ts-state. Matches the audiobookshelf share.
        authKeySecret = null;
        monitorName = "Yoto Share (Tailnet)";
        monitorPath = "/healthz";
      };

      # Separate node so the WebDAV endpoint can be shared (or revoked)
      # independently of the browse URL, and so neither can break the other.
      tailscaleShare.yotodav = lib.mkIf cfg.webdav.enable {
        enable = true;
        fqdn = cfg.webdav.fqdn;
        dataDir = cfg.webdav.dataDir;
        upstream = "http://host.docker.internal:${toString cfg.webdav.port}";
        hostname = "yotodav";
        authKeySecret = null;
        tags = ["tag:share"];
        # Container-to-host traffic is blocked by default; open the rclone port
        # on the podman bridge so the caddy sidecar can reach it.
        firewallPorts = [cfg.webdav.port];
        monitorName = "Yoto WebDAV (Tailnet)";
      };

      # Serving off NFS: a stale handle leaves caddy listing an empty tree,
      # which looks like "the books disappeared" rather than an outage.
      nfsWatchdog.yoto-share = {
        path = cfg.libraryDir;
        unit = "yoto-library.service";
      };

      # rclone holds the share dir open; a stale NFS handle wedges it serving
      # an empty tree, which reads as "the books vanished" rather than an outage.
      nfsWatchdog.yoto-webdav = lib.mkIf cfg.webdav.enable {
        path = cfg.shareDir;
        unit = "yoto-webdav.service";
      };

      # No persistent app state; /healthz reads both source mounts and writes
      # a temporary file. Generation failures after HTTP headers need logs.
      monitoring.errorPatterns = [
        {
          name = "Yoto card download failure";
          unit = "yoto-library.service";
          pattern = "YOTO_DOWNLOAD_FAILED|YOTO_REQUEST_FAILED";
          summary = "Yoto could not prepare or download an audiobook card";
          threshold = 0;
        }
      ];
    };
  };
}
