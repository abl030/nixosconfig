# Yoto share — a pull-only tailnet file drop for audiobooks destined for
# Yoto MYO cards.
#
# Why this exists rather than "just use Audiobookshelf": ABS (and every other
# audiobook app) downloads into its own private app storage, which Android's
# file picker cannot see — and Yoto's uploader is a file picker. On top of
# that, the library is single-file .m4b, often 8+ hours and several hundred
# MB, while Yoto caps a track at 60 min / 100 MB. So the source file is not
# merely awkward to fetch, it is un-uploadable.
#
# `yoto-prep` solves the format half (chapter-split into Yoto-legal tracks,
# packed into card-sized folders, one zip per card); this module solves the
# delivery half (a browsable HTTPS listing on its own tailnet node, serving
# Content-Disposition: attachment so a phone browser writes real files into
# the download folder).
#
# See docs/wiki/services/yoto-share.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.yotoShare;

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
      --set-default YOTO_OUT ${lib.escapeShellArg cfg.shareDir}
  '';
in {
  options.homelab.services.yotoShare = {
    enable = lib.mkEnableOption "Yoto MYO audiobook share (tailnet file drop + yoto-prep tool)";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "yoto.ablz.au";
      description = "FQDN the share is published at on its own tailscale node.";
    };

    shareDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Books/Yoto";
      description = ''
        Directory of prepared, Yoto-ready books served read-only to the
        tailnet. Deliberately a curated staging tree, NOT the audiobook
        library itself: the share has no login, so its contents are exactly
        what any peer the node is shared with can download.
      '';
    };

    libraryDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Books/Audiobooks";
      description = "Audiobookshelf library that yoto-prep reads source books from.";
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
          "--name ${lib.escapeShellArg "Yoto Audiobooks"}"
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
        serveDir = cfg.shareDir;
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
        path = cfg.shareDir;
        unit = "podman-caddy-yoto.service";
      };

      # rclone holds the share dir open; a stale NFS handle wedges it serving
      # an empty tree, which reads as "the books vanished" rather than an outage.
      nfsWatchdog.yoto-webdav = lib.mkIf cfg.webdav.enable {
        path = cfg.shareDir;
        unit = "yoto-webdav.service";
      };

      # Availability is covered by the Kuma monitor the tailscaleShare module
      # registers for the shared URL; caddy sidecar failures surface there.
      monitoring.errorPatterns = [];
    };
  };
}
