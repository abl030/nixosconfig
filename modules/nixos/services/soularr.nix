# Soularr — Lidarr-to-slskd bridge
# =================================
#
# Architecture (all on doc2):
#   Lidarr (port 8686)  ←──pyarr──  soularr  ──slskd-api──→  slskd (port 5030)
#
#   1. Lidarr tracks "wanted" albums (monitored + missing).
#   2. soularr polls Lidarr every 30 min via systemd timer.
#   3. For each wanted album, soularr searches Soulseek via slskd's API.
#   4. When a match is found, soularr tells slskd to download it.
#   5. slskd downloads to the shared downloadDir (/mnt/data/Media/Temp/slskd).
#   6. Lidarr's Completed Download Handling imports from that directory.
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
#   /var/lib/soularr/failure_list.txt        — albums that failed all retries
#   /var/lib/soularr/search_denylist.json    — users/folders to skip
#   /var/lib/soularr/.current_page.txt       — incrementing_page bookmark
#
# Secrets (sops, secrets/soularr.env):
#   SOULARR_LIDARR_API_KEY  — from Lidarr's config.xml <ApiKey>
#   SOULARR_SLSKD_API_KEY   — must match SLSKD_API_KEY in secrets/slskd.env
#
# Debugging:
#   journalctl -u soularr -f              — watch a run in real time
#   sudo systemctl start soularr          — trigger a run now
#   sudo cat /var/lib/soularr/config.ini  — verify API keys & settings
#   sudo -u soularr python3 /nix/store/…-source/soularr.py --help
#                                         — see CLI args (--config-dir, --var-dir, --no-lock-file)
#   curl -s localhost:8686/api/v1/wanted/missing -H 'X-Api-Key: <key>' | jq '.records[].title'
#                                         — check what Lidarr wants
#   curl -s localhost:5030/api/v0/searches -H 'X-API-Key: <key>' | jq
#                                         — check slskd search queue
#
# Config tuning (in configTemplate below):
#   number_of_albums_to_grab   — how many albums per run (default 10)
#   search_timeout             — ms to wait for Soulseek results (default 60000)
#   minimum_filename_match_ratio — fuzzy match threshold (default 0.6)
#   allowed_filetypes          — quality/format priority list
#   stalled_timeout            — seconds before giving up on a stalled download
#
# Boot ordering:
#   All three services (lidarr, slskd, soularr) require mnt-data.mount.
#   NFS local mounts use hard (no bg) so the mount unit blocks until NFS is up.
#   soularr additionally waits for lidarr.service + slskd.service.
#
# Source: github.com/abl030/soularr (fork of mrusse/soularr)
#   Our fork adds a monitored-release preference patch: choose_release()
#   now checks Lidarr's monitored flag first, so it downloads the edition
#   the user selected in the UI rather than the most-common-trackcount release.
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

  # Build soularr from our fork (flake input)
  soularrPkg = let
    pythonEnv = pkgs.python3.withPackages (ps: [
      ps.requests
      ps.configparser
      ps.music-tag
      ps.pyarr
      slskd-api
    ]);
  in
    pkgs.writeShellScriptBin "soularr" ''
      exec ${pythonEnv}/bin/python ${inputs.soularr-src}/soularr.py "$@"
    '';

  # Generate config.ini from module options + sops secrets at runtime
  configTemplate = pkgs.writeText "soularr-config.ini" ''
    [Lidarr]
    api_key = LIDARR_API_KEY_PLACEHOLDER
    host_url = http://localhost:8686
    download_dir = ${cfg.downloadDir}
    disable_sync = False

    [Slskd]
    api_key = SLSKD_API_KEY_PLACEHOLDER
    host_url = http://localhost:5030
    url_base = /
    download_dir = ${cfg.downloadDir}
    delete_searches = False
    stalled_timeout = 3600
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
    allowed_filetypes = mp3 320,mp3 256,m4a 320,m4a 256,aac 320,aac 256,ogg 320,ogg 256,opus 256,opus 192,m4a 16/44.1,flac 24/192,flac 16/44.1,flac,mp3,m4a,aac,ogg,opus
    ignored_users =
    search_for_tracks = True
    album_prepend_artist = True
    track_prepend_artist = True
    search_type = incrementing_page
    number_of_albums_to_grab = 10
    remove_wanted_on_failure = False
    title_blacklist =
    search_blacklist =
    search_source = all
    enable_search_denylist = False
    max_search_failures = 3

    [Download Settings]
    download_filtering = True
    use_extension_whitelist = False
    extensions_whitelist = lrc,nfo,txt

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

    lidarr_key=$(${pkgs.gnugrep}/bin/grep -m1 '^SOULARR_LIDARR_API_KEY=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)
    slskd_key=$(${pkgs.gnugrep}/bin/grep -m1 '^SOULARR_SLSKD_API_KEY=' "$env_file" | ${pkgs.coreutils}/bin/cut -d= -f2-)

    # Generate config.ini with real API keys
    ${pkgs.gnused}/bin/sed \
      -e "s/LIDARR_API_KEY_PLACEHOLDER/$lidarr_key/" \
      -e "s/SLSKD_API_KEY_PLACEHOLDER/$slskd_key/" \
      ${configTemplate} > "$config_dir/config.ini"

    chmod 600 "$config_dir/config.ini"

    # Remove stale lock file from previous SIGTERM'd runs
    rm -f "$config_dir/.soularr.lock"
  '';
in {
  options.homelab.services.soularr = {
    enable = lib.mkEnableOption "Soularr — Lidarr to slskd bridge";

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Temp/slskd";
      description = "Download directory shared between slskd and Lidarr.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."soularr/env" = {
      sopsFile = config.homelab.secrets.sopsFile "soularr.env";
      format = "dotenv";
      owner = "soularr";
      mode = "0400";
    };

    users.users.soularr = {
      isSystemUser = true;
      group = "soularr";
      home = "/var/lib/soularr";
      extraGroups = ["users"];
    };
    users.groups.soularr = {};

    systemd.services.soularr = {
      description = "Soularr - Lidarr to slskd bridge";
      after = ["lidarr.service" "slskd.service" "mnt-data.mount"];
      wants = ["lidarr.service" "slskd.service"];
      requires = ["mnt-data.mount"];
      # Don't block nixos-rebuild — the timer fires every 30 min anyway
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        User = "soularr";
        Group = "soularr";
        ExecStartPre = [
          "+${slskdHealthCheck}" # "+" = run as root to restart slskd if needed
          preStartScript
        ];
        ExecStart = "${soularrPkg}/bin/soularr";
        WorkingDirectory = "/var/lib/soularr";
        StateDirectory = "soularr";
        LoadCredential = "env:${config.sops.secrets."soularr/env".path}";
        ReadWritePaths = [cfg.downloadDir];
      };
    };

    systemd.timers.soularr = {
      description = "Run Soularr periodically";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "30min";
        Persistent = true;
      };
    };
  };
}
