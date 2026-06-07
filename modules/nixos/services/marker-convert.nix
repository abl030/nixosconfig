# marker-convert — PDF -> EPUB conversion, the "last mile" of the magazine
# archive pipeline. Runs on epi (the only fleet box with the RAM + CPU for
# Marker's ML models). Triggered by doc2's gwm-archiver after a new download
# (WOL + SSH), with a weekly RTC self-wake safety net.
#
# See docs/wiki/services/magazine-epub-pipeline.md for the full design and
# docs/wiki/services/magazines.md for the overall system.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.marker-convert;

  batchScript = builtins.path {
    path = ../../../scripts/marker-batch.py;
    name = "marker-batch.py";
  };
  toEpubScript = builtins.path {
    path = ../../../scripts/marker-to-epub.py;
    name = "marker-to-epub.py";
  };

  # nix-ld glue so the uv-installed manylinux torch wheels find their loader.
  # Empirically (the 2026-05 back-catalogue batch) torch needed only the base
  # nix-ld glibc dir; we append the gcc lib dir as belt-and-braces in case a
  # future marker/torch bump wants libstdc++/libgomp from a newer gcc.
  nixLd = "/run/current-system/sw/share/nix-ld/lib/ld.so";
  nixLdLibraryPath = lib.makeLibraryPath [
    "/run/current-system/sw/share/nix-ld"
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  # Tools the wrapper + scripts shell out to.
  runtimePath = lib.makeBinPath [
    pkgs.uv
    pkgs.pandoc
    pkgs.qpdf
    pkgs.poppler-utils
    pkgs.curl
    pkgs.coreutils
    pkgs.gnugrep
  ];

  # ExecStartPre: create the pinned uv venv + install marker-pdf if absent.
  # Idempotent — a populated venv short-circuits. First run is slow (downloads
  # torch + standalone python ~GB, then Marker pulls ~3 GB of Surya models on
  # first conversion into HOME/.cache).
  ensureVenv = pkgs.writeShellScript "marker-ensure-venv" ''
    set -euo pipefail
    export PATH=${runtimePath}:$PATH
    venv="${cfg.stateDir}/venv"
    if [ -x "$venv/bin/marker_single" ]; then
      echo "marker venv present: $venv"
      exit 0
    fi
    echo "creating marker venv at $venv (marker-pdf==${cfg.markerVersion})"
    uv venv "$venv" --python ${cfg.pythonVersion}
    uv pip install --python "$venv/bin/python" "marker-pdf==${cfg.markerVersion}"
    echo "marker venv ready"
  '';

  # ExecStart: run the batch, then poke Komga so the new EPUB shows up
  # immediately (kills the "Gotify says new issue but it's not in Komga" gap).
  convert = pkgs.writeShellScript "marker-convert-run" ''
    set -euo pipefail
    export PATH=${runtimePath}:$PATH
    export NIX_LD=${nixLd}
    export NIX_LD_LIBRARY_PATH=${nixLdLibraryPath}
    venv="${cfg.stateDir}/venv"

    echo "== marker-convert: scanning ${cfg.archiveRoot} for PDFs missing EPUBs =="
    ARCHIVE_ROOT=${cfg.archiveRoot} \
    WORKERS=${toString cfg.workers} \
    MARKER_BIN="$venv/bin/marker_single" \
    TO_EPUB=${toEpubScript} \
    PANDOC_BIN=${pkgs.pandoc}/bin/pandoc \
      "$venv/bin/python" ${batchScript} || rc=$?
    rc=''${rc:-0}

    # Trigger a Komga rescan regardless of per-issue errors, so any EPUBs that
    # DID land become visible without waiting for Komga's daily auto-scan.
    if [ -r "${cfg.komgaKeyFile}" ]; then
      key="$(grep -E '^KOMGA_API_KEY=' "${cfg.komgaKeyFile}" | head -1 | cut -d= -f2-)"
      for lib in ${lib.concatStringsSep " " cfg.komgaLibraryIds}; do
        echo "== komga scan: library $lib =="
        curl -fsS -X POST -H "X-API-Key: $key" \
          "${cfg.komgaUrl}/api/v1/libraries/$lib/scan" || true
      done
    else
      echo "WARN: ${cfg.komgaKeyFile} unreadable; skipping Komga rescan" >&2
    fi
    exit "$rc"
  '';
in {
  options.homelab.services.marker-convert = {
    enable = lib.mkEnableOption "Marker PDF->EPUB conversion (magazine last mile)";

    archiveRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Magazines";
      description = "Root walked for PDFs lacking an EPUB sibling.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/marker-convert";
      description = "Holds the pinned uv venv + the model cache (HOME).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "abl030";
      description = ''
        User the conversion runs as. Must have write access to the NFS
        archive (the human account does; a fresh system user would hit
        NFS uid-mapping issues on the tower export).
      '';
    };

    workers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Parallel marker_single workers (~14 GB RAM each).";
    };

    pythonVersion = lib.mkOption {
      type = lib.types.str;
      default = "3.12";
      description = "Python for the uv venv.";
    };

    markerVersion = lib.mkOption {
      type = lib.types.str;
      default = "1.10.2";
      description = ''
        Pinned marker-pdf version. Bump deliberately and re-test — Marker's
        output shape (heading detection, table handling) drifts across
        releases and the post-processor's fuzzy matcher is tuned to it.
        Delete ${cfg.stateDir}/venv to force a reinstall after a bump.
      '';
    };

    komgaUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://magazines.ablz.au";
      description = "Komga base URL for the post-conversion rescan.";
    };

    komgaLibraryIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["0QFB0VEFMZBE3" "0QFB0WAJ0Z3KF"];
      description = "Komga library IDs to rescan after conversion (GAW, WVJ).";
    };

    komgaKeyFile = lib.mkOption {
      type = lib.types.str;
      default = config.sops.secrets."marker-convert/komga-key".path;
      description = "Path to the dotenv holding KOMGA_API_KEY.";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "Mon *-*-* 05:00:00 Australia/Perth";
      description = ''
        RTC self-wake safety-net schedule. The primary trigger is event-driven
        (doc2 WOL + SSH after a download); this weekly wake catches anything a
        missed WOL left unconverted.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."marker-convert/komga-key" = {
      sopsFile = config.homelab.secrets.sopsFile "komga-sync.env";
      format = "dotenv";
      mode = "0400";
      owner = cfg.user;
    };

    systemd.services.marker-convert = {
      description = "Convert magazine PDFs to EPUB (Marker) + rescan Komga";
      # NFS archive must be present. Wants= not Requires= so a transient mount
      # blip doesn't hard-fail; the script no-ops cleanly if the tree is empty.
      after = ["network-online.target" "remote-fs.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # HOME under the state dir so uv + HF/torch/surya caches persist there
        # and survive across runs (the 3 GB model download happens once).
        Environment = ["HOME=${cfg.stateDir}"];
        StateDirectory = "marker-convert";
        StateDirectoryMode = "0750";
        WorkingDirectory = cfg.stateDir;

        ExecStartPre = ensureVenv;
        ExecStart = convert;

        # Be a polite guest on the workstation: lowest CPU + idle IO so an
        # in-progress conversion never fights the user if they're at the desk.
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUWeight = 20;

        # First run installs torch + downloads models; give it room. A full
        # back-catalogue (123 issues) is ~30 h, but the event-driven path only
        # ever has 1 new issue to do (~35 min).
        TimeoutStartSec = "48h";

        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "marker-convert";
      };
    };

    systemd.timers.marker-convert = {
      description = "Weekly RTC-wake safety net for marker-convert";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        # Self-wake epi from suspend-to-RAM, same mechanism as nixos-upgrade.
        WakeSystem = true;
        RandomizedDelaySec = "10m";
      };
    };

    # Let the trigger user start (only) this unit without a password, so doc2's
    # `ssh ${user}@epi systemctl start marker-convert.service` works over the
    # existing master-key SSH trust — no sudo, no new SSH keys, scoped to one
    # unit. doc2's gwm-archiver fires this after a new download.
    security.polkit.extraConfig = ''
      // marker-convert: allow ${cfg.user} to start the conversion unit
      // (remote trigger from doc2 after a new magazine download).
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "marker-convert.service" &&
            action.lookup("verb") == "start" &&
            subject.user == "${cfg.user}") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
