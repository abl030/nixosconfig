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
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [yoto-prep];

    homelab = {
      tailscaleShare.yoto = {
        enable = true;
        inherit (cfg) fqdn dataDir;
        serveDir = cfg.shareDir;
        hostname = "yoto";
        # First run logs a login URL in `podman logs ts-yoto`; state then
        # persists under dataDir/ts-state. Matches the audiobookshelf share.
        authKeySecret = null;
        monitorName = "Yoto Share (Tailnet)";
      };

      # Serving off NFS: a stale handle leaves caddy listing an empty tree,
      # which looks like "the books disappeared" rather than an outage.
      nfsWatchdog.yoto-share = {
        path = cfg.shareDir;
        unit = "podman-caddy-yoto.service";
      };

      # Availability is covered by the Kuma monitor the tailscaleShare module
      # registers for the shared URL; caddy sidecar failures surface there.
      monitoring.errorPatterns = [];
    };
  };
}
