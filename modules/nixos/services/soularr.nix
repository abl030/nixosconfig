# Soularr — Soulseek download pipeline
# =================================
#
# Architecture (all on doc2):
#   Pipeline DB (PostgreSQL)  ←──  soularr  ──slskd-api──→  slskd (port 5030)
#
#   1. Pipeline DB tracks wanted albums (via web UI or pipeline-cli).
#   2. soularr polls the DB every 5 min via systemd timer.
#   3. For each wanted album, soularr searches Soulseek via slskd's API.
#   4. When a match is found, soularr tells slskd to download it.
#   5. Downloads are validated via beets, then auto-imported or staged.
#
# Network topology:
#   doc2 has two NICs on 192.168.1.0/24:
#     ens18 = 192.168.1.35 (main, DHCP) — Lidarr, soularr, NFS, everything else
#     ens19 = 192.168.1.36 (VPN, static) — slskd Soulseek traffic only
#   Policy routing (see slskd.nix):
#     - LAN subnet forced via ens18 so NFS/DNS don't get VPN-routed
#     - UID-based rule sends all slskd traffic via table 100 → ens19 → pfSense → WireGuard
#     - Verify: sudo -u slskd curl ifconfig.co → should show VPN exit IP
#
# Key files on doc2:
#   /var/lib/soularr/config.ini    — generated at runtime by preStartScript
#   /var/lib/soularr/.soularr.lock — lock file (cleaned up on restart)
#
# Secrets (sops, secrets/soularr.env):
#   SOULARR_SLSKD_API_KEY   — must match SLSKD_API_KEY in secrets/slskd.env
#
# Debugging:
#   journalctl -u soularr -f              — watch a run in real time
#   sudo systemctl start soularr          — trigger a run now
#   sudo cat /var/lib/soularr/config.ini  — verify API keys & settings
#   sudo -u soularr python3 /nix/store/…-source/soularr.py --help
#                                         — see CLI args (--config-dir, --var-dir, --no-lock-file)
#   curl -s localhost:5030/api/v0/searches -H 'X-API-Key: <key>' | jq
#                                         — check slskd search queue
#
# Config tuning (in configTemplate below):
#   number_of_albums_to_grab   — how many albums per run (default 16)
#   parallel_searches          — concurrent search threads (default 8, set 1 for sequential)
#   search_timeout             — ms to wait for Soulseek results (default 60000)
#   minimum_filename_match_ratio — fuzzy match threshold (default 0.6)
#   allowed_filetypes          — quality/format priority list
#   stalled_timeout            — seconds before giving up on a stalled download
#
# Boot ordering:
#   Both services (slskd, soularr) require mnt-data.mount.
#   NFS local mounts use hard (no bg) so the mount unit blocks until NFS is up.
#   soularr additionally waits for slskd.service + soularr-db container.
#
# Source: github.com/abl030/soularr (fork of mrusse/soularr)
#   Pipeline DB is the sole source of truth. Web UI at music.ablz.au.
#   Pinned via flake input soularr-src (flake = false).
# Not in nixpkgs — built inline. slskd-api (PyPI) also built inline.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.homelab.services.soularr;

  # PostgreSQL in an nspawn container — data lives at cfg.dataDir/postgres
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "soularr";
    hostNum = 5;
    dataDir = cfg.dataDir;
  };

  # slskd-api is not in nixpkgs — build from PyPI
  slskd-api = pkgs.python3Packages.buildPythonPackage {
    pname = "slskd-api";
    version = "0.1.5";
    pyproject = true;
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/74/eb/b1e43d099cca89d313352b3ac0ae1100494c5f7b4a727dde82b89b2a0ca9/slskd-api-0.1.5.tar.gz";
      hash = "sha256-LmWP7bnK5IVid255qS2NGOmyKzGpUl3xsO5vi5uJI88=";
    };
    build-system = with pkgs.python3Packages; [setuptools setuptools-git-versioning];
    dependencies = with pkgs.python3Packages; [requests];
    doCheck = false;
  };

  # Python environment with all soularr dependencies
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.requests
    ps.configparser
    ps.music-tag
    ps.psycopg2
    slskd-api
  ]);

  # Build soularr from our fork (flake input)
  soularrPkg = pkgs.writeShellScriptBin "soularr" ''
    exec ${pythonEnv}/bin/python ${inputs.soularr-src}/soularr.py "$@"
  '';

  # CLI wrapper — `pipeline-cli status`, `pipeline-cli list wanted`, etc.
  pipelineCli = pkgs.writeShellScriptBin "pipeline-cli" ''
    export PATH="${pkgs.ffmpeg}/bin:${pkgs.sox}/bin:${pkgs.mp3val}/bin:${pkgs.flac}/bin:$PATH"
    export PYTHONPATH="${inputs.soularr-src}/lib:''${PYTHONPATH:-}"
    exec ${pythonEnv}/bin/python ${inputs.soularr-src}/scripts/pipeline_cli.py \
      --dsn "${cfg.pipelineDb.dsn}" "$@"
  '';

  # Web UI service — music.ablz.au
  webPkg = pkgs.writeShellScriptBin "soularr-web" ''
    export PYTHONPATH="${inputs.soularr-src}/lib:${inputs.soularr-src}/web:''${PYTHONPATH:-}"
    exec ${pythonEnv}/bin/python ${inputs.soularr-src}/web/server.py \
      --port ${toString cfg.web.port} \
      --dsn "${cfg.pipelineDb.dsn}" \
      --beets-db "${cfg.web.beetsDb}" "$@"
  '';

  # Generate config.ini from module options + sops secrets at runtime
  configTemplate = pkgs.writeText "soularr-config.ini" ''
    [Slskd]
    api_key = SLSKD_API_KEY_PLACEHOLDER
    host_url = http://localhost:5030
    url_base = /
    download_dir = ${cfg.downloadDir}
    delete_searches = True
    stalled_timeout = 600
    remote_queue_timeout = 300

    [Release Settings]
    use_most_common_tracknum = True
    allow_multi_disc = True
    accepted_countries = Europe,Japan,United Kingdom,United States,[Worldwide],Australia,Canada
    skip_region_check = False
    accepted_formats = CD,Digital Media,Vinyl

    [Search Settings]
    search_timeout = 60000
    maximum_peer_queue = 50
    minimum_peer_upload_speed = 0
    minimum_filename_match_ratio = 0.6
    allowed_filetypes = mp3 v0,mp3 320,flac 24/192,flac 24/96,flac 24/48,flac 16/44.1,flac,alac,aac 256+,ogg 256+,opus 192+
    ignored_users =
    search_for_tracks = True
    album_prepend_artist = True
    track_prepend_artist = True
    search_type = incrementing_page
    parallel_searches = 8
    number_of_albums_to_grab = 16
    title_blacklist =
    search_blacklist =

    [Download Settings]
    download_filtering = True
    use_extension_whitelist = False
    extensions_whitelist = lrc,nfo,txt

    [Beets Validation]
    enabled = ${
      if cfg.beetsValidation.enable
      then "True"
      else "False"
    }
    harness_path = ${cfg.beetsValidation.harnessPath}
    distance_threshold = ${toString cfg.beetsValidation.distanceThreshold}
    staging_dir = ${cfg.beetsValidation.stagingDir}
    tracking_file = ${cfg.beetsValidation.trackingFile}

    [Pipeline DB]
    enabled = ${
      if cfg.pipelineDb.enable
      then "True"
      else "False"
    }
    dsn = ${cfg.pipelineDb.dsn}

    [Meelo]
    url = http://192.168.1.29:5001
    username = MEELO_USERNAME_PLACEHOLDER
    password = MEELO_PASSWORD_PLACEHOLDER

    [Logging]
    level = INFO
    format = [%(levelname)s|%(module)s|L%(lineno)d] %(asctime)s: %(message)s
    datefmt = %Y-%m-%dT%H:%M:%S%z
  '';

  # Health check that runs as root (via "+" prefix) before each soularr run.
  # If slskd is disconnected from Soulseek (stuck reconnect loop bug),
  # restart the service — a fresh process reconnects immediately.
  slskdHealthCheck = pkgs.writeShellScript "soularr-slskd-healthcheck" ''
    set -euo pipefail
    api_key=$(${pkgs.gnugrep}/bin/grep -m1 '^SOULARR_SLSKD_API_KEY=' "/run/secrets/soularr/env" | ${pkgs.coreutils}/bin/cut -d= -f2-)
    status=$(${pkgs.curl}/bin/curl -sf -H "X-API-Key: $api_key" http://localhost:5030/api/v0/server 2>/dev/null || echo '{}')
    connected=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.isConnected // false')
    logged_in=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.isLoggedIn // false')
    if [ "$connected" = "true" ] && [ "$logged_in" = "true" ]; then
      exit 0
    fi
    echo "soularr: slskd not connected (connected=$connected, loggedIn=$logged_in), restarting slskd..." >&2
    ${pkgs.systemd}/bin/systemctl restart slskd.service
    # Give it time to connect and log in
    for i in $(seq 1 12); do
      sleep 5
      status=$(${pkgs.curl}/bin/curl -sf -H "X-API-Key: $api_key" http://localhost:5030/api/v0/server 2>/dev/null || echo '{}')
      logged_in=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.isLoggedIn // false')
      if [ "$logged_in" = "true" ]; then
        echo "soularr: slskd reconnected after restart" >&2
        exit 0
      fi
    done
    echo "soularr: slskd failed to reconnect after restart, skipping run" >&2
    exit 1
  '';

  preStartScript = pkgs.writeShellScript "soularr-prestart" ''
    set -euo pipefail
    config_dir="/var/lib/soularr"
    mkdir -p "$config_dir"

    # Read API keys from sops env file
    env_file="$CREDENTIALS_DIRECTORY/env"
    if [[ ! -r "$env_file" ]]; then
      echo "soularr: env file not readable" >&2
      exit 1
    fi

    slskd_key=$(${pkgs.gnugrep}/bin/grep -m1 '^SOULARR_SLSKD_API_KEY=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)
    meelo_user=$(${pkgs.gnugrep}/bin/grep -m1 '^MEELO_USERNAME=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)
    meelo_pass=$(${pkgs.gnugrep}/bin/grep -m1 '^MEELO_PASSWORD=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)

    # Generate config.ini with real API keys
    ${pkgs.gnused}/bin/sed \
      -e "s/SLSKD_API_KEY_PLACEHOLDER/$slskd_key/" \
      -e "s/MEELO_USERNAME_PLACEHOLDER/$meelo_user/" \
      -e "s/MEELO_PASSWORD_PLACEHOLDER/$meelo_pass/" \
      ${configTemplate} > "$config_dir/config.ini"

    chmod 600 "$config_dir/config.ini"

    # Remove stale lock file from previous SIGTERM'd runs
    rm -f "$config_dir/.soularr.lock"

  '';
in {
  options.homelab.services.soularr = {
    enable = lib.mkEnableOption "Soularr — Soulseek download pipeline";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/soularr";
      description = "Directory for all Soularr state (contains postgres subdirectory).";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Temp/slskd";
      description = "Download directory for slskd.";
    };

    beetsValidation = {
      enable = lib.mkEnableOption "Beets validation for downloaded albums";

      harnessPath = lib.mkOption {
        type = lib.types.str;
        default = "${inputs.soularr-src}/harness/run_beets_harness.sh";
        description = "Path to the beets harness wrapper script.";
      };

      distanceThreshold = lib.mkOption {
        type = lib.types.float;
        default = 0.15;
        description = "Maximum beets match distance to accept (0.0 = perfect, 1.0 = no match).";
      };

      stagingDir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/virtio/Music/Incoming";
        description = "Directory to stage validated albums for beets import.";
      };

      trackingFile = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/virtio/Music/Re-download/beets-validated.jsonl";
        description = "JSONL file tracking beets validation results.";
      };
    };

    pipelineDb = {
      enable = lib.mkEnableOption "Pipeline DB (PostgreSQL, source of truth for wanted albums)";

      dsn = lib.mkOption {
        type = lib.types.str;
        default = pgc.dbUri;
        description = "PostgreSQL connection string for the pipeline database.";
      };
    };

    web = {
      enable = lib.mkEnableOption "music.ablz.au web UI for browsing and requesting albums";

      port = lib.mkOption {
        type = lib.types.port;
        default = 8085;
        description = "Port for the web UI.";
      };

      beetsDb = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/virtio/Music/beets-library.db";
        description = "Path to the beets library SQLite database (read-only).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Put pipeline-cli on system PATH for easy SSH access from doc1
    environment.systemPackages = [pipelineCli pkgs.postgresql];

    sops.secrets."soularr/env" = {
      sopsFile = config.homelab.secrets.sopsFile "soularr.env";
      format = "dotenv";
      owner = "root";
      mode = "0400";
    };

    # PostgreSQL nspawn container
    containers.soularr-db = pgc.containerConfig;

    # Ensure data directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/postgres 0700 root root -"
    ];

    # Soularr runs as root — needs access to slskd downloads, beets
    # harness (Nix python env), and full PATH for subprocess calls.

    systemd.services.soularr = {
      description = "Soularr - Soulseek download pipeline";
      after = ["slskd.service" "container@soularr-db.service"];
      wants = ["slskd.service" "container@soularr-db.service"];
      # Don't block nixos-rebuild — the timer fires every 30 min anyway
      restartIfChanged = false;
      path = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.curl pkgs.jq pkgs.python3 pkgs.ffmpeg pkgs.mp3val pkgs.flac pkgs.sox];
      serviceConfig = {
        Type = "oneshot";
        # Run as root — avoids permission/PATH issues with slskd downloads,
        # beets harness (needs Nix python env), and systemd restricted PATH.
        UMask = "0000";
        ExecStartPre = [
          slskdHealthCheck
          preStartScript
        ];
        Environment = "PIPELINE_DB_DSN=${cfg.pipelineDb.dsn}";
        ExecStart = "${soularrPkg}/bin/soularr";
        WorkingDirectory = "/var/lib/soularr";
        StateDirectory = "soularr";
        LoadCredential = "env:${config.sops.secrets."soularr/env".path}";
      };
    };

    systemd.timers.soularr = {
      description = "Run Soularr periodically";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };

    # Web UI for browsing MusicBrainz and adding albums to the pipeline
    systemd.services.soularr-web = lib.mkIf cfg.web.enable {
      description = "Soularr Web UI - music.ablz.au";
      after = ["container@soularr-db.service"];
      wants = ["container@soularr-db.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${webPkg}/bin/soularr-web";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = "PIPELINE_DB_DSN=${cfg.pipelineDb.dsn}";
      };
    };

    homelab.localProxy.hosts = lib.mkIf cfg.web.enable [
      {
        host = "music.ablz.au";
        port = cfg.web.port;
      }
    ];
  };
}
