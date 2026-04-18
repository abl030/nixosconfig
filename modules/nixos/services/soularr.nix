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
    ps.redis
    ps.msgspec
    slskd-api
  ]);

  # Build soularr from our fork (flake input)
  soularrPkg = pkgs.writeShellScriptBin "soularr" ''
    exec ${pythonEnv}/bin/python ${inputs.soularr-src}/soularr.py "$@"
  '';

  # CLI wrapper — `pipeline-cli status`, `pipeline-cli list wanted`, etc.
  # PYTHONPATH exposes only the repo root so every module has a single canonical
  # import path (`lib.X`, `web.X`, `scripts.X`). Listing `lib/` / `web/` here
  # would let the same module load twice with distinct class objects (issue #95).
  pipelineCli = pkgs.writeShellScriptBin "pipeline-cli" ''
    export PATH="${pkgs.ffmpeg}/bin:${pkgs.sox}/bin:${pkgs.mp3val}/bin:${pkgs.flac}/bin:$PATH"
    export PYTHONPATH="${inputs.soularr-src}:''${PYTHONPATH:-}"
    exec ${pythonEnv}/bin/python ${inputs.soularr-src}/scripts/pipeline_cli.py \
      --dsn "${cfg.pipelineDb.dsn}" "$@"
  '';

  # Schema migrator — applies any pending migrations/*.sql files via the
  # versioned migrator (lib/migrator.py). Idempotent: a no-op if the schema
  # is already current. Run as a oneshot systemd unit on every rebuild.
  pipelineMigrate = pkgs.writeShellScriptBin "pipeline-migrate" ''
    export PYTHONPATH="${inputs.soularr-src}:''${PYTHONPATH:-}"
    exec ${pythonEnv}/bin/python ${inputs.soularr-src}/scripts/migrate_db.py \
      --dsn "${cfg.pipelineDb.dsn}" \
      --migrations-dir "${inputs.soularr-src}/migrations" "$@"
  '';

  # Web UI service — music.ablz.au
  # PATH includes tools needed by import_one.py (manual import feature)
  webPkg = pkgs.writeShellScriptBin "soularr-web" ''
    export PATH="${pkgs.bash}/bin:${pkgs.ffmpeg}/bin:${pkgs.sox}/bin:${pkgs.mp3val}/bin:${pkgs.flac}/bin:$PATH"
    export PYTHONPATH="${inputs.soularr-src}:''${PYTHONPATH:-}"
    exec ${pythonEnv}/bin/python ${inputs.soularr-src}/web/server.py \
      --port ${toString cfg.web.port} \
      --dsn "${cfg.pipelineDb.dsn}" \
      --beets-db "${cfg.web.beetsDb}" \
      --redis-host 127.0.0.1 "$@"
  '';

  # [Quality Ranks] section renderer — mirrors lib/quality.py:QualityRankConfig.defaults().
  # Pinned on the Python side by TestQualityRankConfigDefaults in
  # tests/test_quality_decisions.py — if you change a default here, also update the
  # Python dataclass (and vice versa). The pin test fails loudly on drift.
  # See soularr's README § "Tuning the quality rank model" for every option's meaning.
  qualityRanksSection = let
    qr = cfg.qualityRanks;
    bandSection = codecKey: bands: ''
      ${codecKey}.transparent = ${toString bands.transparent}
      ${codecKey}.excellent = ${toString bands.excellent}
      ${codecKey}.good = ${toString bands.good}
      ${codecKey}.acceptable = ${toString bands.acceptable}
    '';
    # Strip the trailing newline so that the parent template's own newline
    # produces exactly one blank line between this section and the next
    # (matches the spacing of the other [Section] blocks in configTemplate).
  in
    lib.strings.removeSuffix "\n" ''
      [Quality Ranks]
      # Declarative mirror of lib/quality.py:QualityRankConfig.defaults(). Retune
      # via homelab.services.soularr.qualityRanks.* in this module (NOT by hand
      # editing config.ini — Nix regenerates this file on every rebuild).
      bitrate_metric = ${qr.bitrateMetric}
      gate_min_rank = ${qr.gateMinRank}
      within_rank_tolerance_kbps = ${toString qr.withinRankToleranceKbps}

      ${bandSection "opus" qr.bands.opus}
      ${bandSection "mp3_vbr" qr.bands.mp3Vbr}
      ${bandSection "mp3_cbr" qr.bands.mp3Cbr}
      ${bandSection "aac" qr.bands.aac}
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
    remote_queue_timeout = 3600

    [Release Settings]
    use_most_common_tracknum = True
    allow_multi_disc = True
    accepted_countries = Europe,Japan,United Kingdom,United States,[Worldwide],Australia,Canada
    skip_region_check = False
    accepted_formats = CD,Digital Media,Vinyl

    [Search Settings]
    search_timeout = 30000
    maximum_peer_queue = 50
    minimum_peer_upload_speed = 0
    minimum_filename_match_ratio = 0.6
    # Priority-ordered filetype list. The rank model in lib/quality.py is the
    # authoritative quality decision (post-download); this filter is only for
    # search-time peer/codec preference. High-quality tiers lead so curation
    # picks transparent MP3 or hi-res FLAC first; bare-codec tiers at the end
    # are the permissive fallback (any MP3, any Opus, any AAC, any OGG, any
    # WAV) so the rank model sees everything and can make the call via its
    # codec-aware bands. See soularr README § "Tuning the quality rank model"
    # for the design rationale.
    allowed_filetypes = mp3 v0,mp3 320,flac 24/192,flac 24/96,flac 24/48,flac 16/44.1,flac,alac,aac,opus,ogg,mp3,wav
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
    verified_lossless_target = ${cfg.beetsValidation.verifiedLosslessTarget}

    ${qualityRanksSection}
    [Pipeline DB]
    enabled = ${
      if cfg.pipelineDb.enable
      then "True"
      else "False"
    }
    dsn = ${cfg.pipelineDb.dsn}

    [Meelo]
    url = https://meelo.ablz.au
    username = MEELO_USERNAME_PLACEHOLDER
    password = MEELO_PASSWORD_PLACEHOLDER

    [Plex]
    url = https://plex.ablz.au
    token = PLEX_TOKEN_PLACEHOLDER
    library_section_id = 3
    path_map = /mnt/virtio/Music/Beets:/prom_music

    [Jellyfin]
    url = https://jelly.ablz.au
    token = JELLYFIN_TOKEN_PLACEHOLDER

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
    plex_token=$(${pkgs.gnugrep}/bin/grep -m1 '^PLEX_TOKEN=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2- || true)
    jellyfin_token=$(${pkgs.gnugrep}/bin/grep -m1 '^JELLYFIN_TOKEN=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2- || true)

    # Generate config.ini with real API keys
    ${pkgs.gnused}/bin/sed \
      -e "s/SLSKD_API_KEY_PLACEHOLDER/$slskd_key/" \
      -e "s/MEELO_USERNAME_PLACEHOLDER/$meelo_user/" \
      -e "s/MEELO_PASSWORD_PLACEHOLDER/$meelo_pass/" \
      -e "s/PLEX_TOKEN_PLACEHOLDER/$plex_token/" \
      -e "s/JELLYFIN_TOKEN_PLACEHOLDER/$jellyfin_token/" \
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

      verifiedLosslessTarget = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Target format after verified lossless (e.g. 'opus 128', 'mp3 v2'). Empty = keep V0.";
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

    # -----------------------------------------------------------------------
    # Codec-aware quality rank model (issues #60, #64, #65, #66, #67, #68)
    # -----------------------------------------------------------------------
    # Declarative mirror of lib/quality.py:QualityRankConfig.defaults() in the
    # soularr repo. Every default here equals what Python would use if no
    # [Quality Ranks] section existed in config.ini. Retuning any option
    # regenerates /var/lib/soularr/config.ini on the next rebuild and Soularr
    # picks it up on its next 5-min timer fire.
    #
    # DRIFT PROTECTION: every default is pinned by TestQualityRankConfigDefaults
    # in tests/test_quality_decisions.py (soularr repo). The pin test fails
    # loudly when the *Python* defaults change, reminding the developer to
    # update the Nix mirror too. Nix-side overrides (setting a value here
    # that differs from Python defaults) are visible by design — that's the
    # whole point of declarative visibility — and do NOT trigger the pin
    # test. To match Python exactly, leave options at their documented
    # defaults; to tune, override here and accept that config.ini wins over
    # QualityRankConfig.defaults() at runtime.
    #
    # FULL OPTION REFERENCE: soularr's README § "Tuning the quality rank model"
    # documents what every option means and when to retune.
    qualityRanks = let
      mkCodecBands = codec: defaults: {
        transparent = lib.mkOption {
          type = lib.types.int;
          default = defaults.transparent;
          description = ''
            ${codec} TRANSPARENT rank floor (kbps). Measurements at or above
            this bitrate classify as TRANSPARENT under the bare-codec band
            table (used when the format hint is a plain codec string rather
            than an explicit label like "mp3 v0"). See README § Tuning the
            quality rank model.
          '';
        };
        excellent = lib.mkOption {
          type = lib.types.int;
          default = defaults.excellent;
          description = "${codec} EXCELLENT rank floor (kbps).";
        };
        good = lib.mkOption {
          type = lib.types.int;
          default = defaults.good;
          description = "${codec} GOOD rank floor (kbps).";
        };
        acceptable = lib.mkOption {
          type = lib.types.int;
          default = defaults.acceptable;
          description = "${codec} ACCEPTABLE rank floor (kbps).";
        };
      };
    in {
      gateMinRank = lib.mkOption {
        type = lib.types.enum [
          "unknown"
          "poor"
          "acceptable"
          "good"
          "excellent"
          "transparent"
          "lossless"
        ];
        default = "excellent";
        description = ''
          Minimum rank an imported album must reach before the post-import
          quality gate accepts it. Below this → re-queue for upgrade.
          Raise to tighten (reject more albums); lower to accept
          lower-quality sources. Mirrors cfg.gate_min_rank in Python.
        '';
      };

      bitrateMetric = lib.mkOption {
        type = lib.types.enum ["min" "avg" "median"];
        default = "avg";
        description = ''
          Which per-album bitrate statistic feeds rank classification.
          "avg" is robust to VBR per-track variance. "median" is
          outlier-resistant — prefer when albums commonly have quiet
          intros/hidden tracks/skits that skew "avg" (#64). "min" is
          legacy and penalizes legitimately-encoded lo-fi VBR.
        '';
      };

      withinRankToleranceKbps = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = ''
          Same-rank equivalence window in kbps. Two bare-codec
          measurements in the same rank tier within this tolerance
          are "equivalent"; outside it, one is "better"/"worse".
        '';
      };

      bands = {
        # Opus unconstrained VBR typical 120-135 kbps, per-track 95-150.
        # 112 leaves headroom for sparse material; 88 matches Opus 96
        # hydrogenaudio quality (Kamedo2 4.65/5).
        opus = mkCodecBands "Opus" {
          transparent = 112;
          excellent = 88;
          good = 64;
          acceptable = 48;
        };

        # excellent=210 preserves the legacy QUALITY_MIN_BITRATE_KBPS=210
        # gate threshold. Also feeds transcode_detection() as the
        # spectral-fallback threshold (#66) — lowering this implicitly
        # lowers what counts as "credible V0" when spectral is unavailable.
        mp3Vbr = mkCodecBands "MP3 VBR" {
          transparent = 245;
          excellent = 210;
          good = 170;
          acceptable = 130;
        };

        # Unverifiable CBR is only transparent at 320 — we can't prove
        # a CBR file came from lossless source. Below that → requeue
        # for a FLAC source to re-verify.
        mp3Cbr = mkCodecBands "MP3 CBR" {
          transparent = 320;
          excellent = 256;
          good = 192;
          acceptable = 128;
        };

        # Hydrogenaudio consensus places the "no meaningful gain above
        # here" music ceiling at 192 kbps.
        aac = mkCodecBands "AAC" {
          transparent = 192;
          excellent = 144;
          good = 112;
          acceptable = 80;
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Put pipeline-cli + pipeline-migrate on system PATH for easy SSH access
    environment.systemPackages = [pipelineCli pipelineMigrate pkgs.postgresql];

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

    # Pipeline DB schema migrator
    # ---------------------------
    # Versioned migrations live in ${inputs.soularr-src}/migrations/*.sql.
    # This oneshot runs the migrator on every nixos-rebuild switch (because
    # restartIfChanged = true), so the prod schema is always brought current
    # BEFORE soularr.service or soularr-web.service start touching the DB.
    #
    # The migrator is idempotent: if every shipped migration is already
    # recorded in schema_migrations, the run is a fast no-op.
    #
    # RemainAfterExit = true keeps the unit "active" so dependent services
    # can express requires/after on it without needing to re-run it on every
    # cycle of the soularr.timer.
    systemd.services.soularr-db-migrate = {
      description = "Apply Pipeline DB schema migrations";
      after = ["container@soularr-db.service"];
      requires = ["container@soularr-db.service"];
      wantedBy = ["multi-user.target"];
      restartIfChanged = true;
      # restartTriggers: oneshot with RemainAfterExit=true is cascade-stopped to
      # `inactive` (not `active (exited)`) when its DB container restarts.
      # Pinning the container unit derivation here ensures switch-to-configuration
      # explicitly re-runs the migrator on every relevant change.  See PR for
      # the broader pattern.
      restartTriggers = [config.systemd.units."container@soularr-db.service".unit];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = "PIPELINE_DB_DSN=${cfg.pipelineDb.dsn}";
        ExecStart = "${pipelineMigrate}/bin/pipeline-migrate";
      };
    };

    # Soularr runs as root — needs access to slskd downloads, beets
    # harness (Nix python env), and full PATH for subprocess calls.

    systemd.services.soularr = {
      description = "Soularr - Soulseek download pipeline";
      after = ["slskd.service" "container@soularr-db.service" "soularr-db-migrate.service"];
      wants = ["slskd.service" "container@soularr-db.service"];
      requires = ["soularr-db-migrate.service"];
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

    # Redis cache for the web UI (in-memory only, no persistence)
    services.redis.servers.soularr = lib.mkIf cfg.web.enable {
      enable = true;
      port = 6379;
      save = []; # no persistence — pure cache
    };

    # Web UI for browsing MusicBrainz and adding albums to the pipeline.
    # restartTriggers: soularr-web uses Wants= (not Requires=) so won't be
    # cascade-stopped, but we still want it restarted when the DB container
    # is rebuilt to pick up any schema/extension changes.
    systemd.services.soularr-web = lib.mkIf cfg.web.enable {
      description = "Soularr Web UI - music.ablz.au";
      after = ["container@soularr-db.service" "redis-soularr.service" "soularr-db-migrate.service"];
      wants = ["container@soularr-db.service" "redis-soularr.service"];
      # requires soularr-db-migrate so soularr-web can't come up against an
      # un-migrated schema. The migrate unit is a oneshot with
      # RemainAfterExit=true, so this hard dep doesn't trigger spurious
      # cascade-stops during normal operation.
      requires = ["soularr-db-migrate.service"];
      restartTriggers = [config.systemd.units."container@soularr-db.service".unit];
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
