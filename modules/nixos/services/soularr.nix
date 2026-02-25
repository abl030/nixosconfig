{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.soularr;

  # slskd-api is not in nixpkgs — build from PyPI
  slskd-api = pkgs.python3Packages.buildPythonPackage {
    pname = "slskd-api";
    version = "0.1.5";
    pyproject = true;
    src = pkgs.fetchPypi {
      pname = "slskd_api";
      version = "0.1.5";
      hash = "sha256-TP6IvdO3N+xHl6ypE+f3aTqYdJPFJvq0OHhVNDUbE80=";
    };
    build-system = with pkgs.python3Packages; [setuptools];
    dependencies = with pkgs.python3Packages; [requests];
    doCheck = false;
  };

  # Build soularr from upstream
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
      exec ${pythonEnv}/bin/python ${soularrSrc}/soularr.py "$@"
    '';

  soularrSrc = pkgs.fetchFromGitHub {
    owner = "mrusse";
    repo = "soularr";
    rev = "6a8778019581769a035092b73b5fe4c4daa64f82";
    hash = "sha256-kDL4kQLOFYrlJslelyDlDWs3PO6ml2b+oHTI2HzUsaU=";
  };

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
    allowed_filetypes = mp3 320,mp3 256,m4a 320,m4a 256,aac 320,aac 256,ogg 320,ogg 256,opus 256,opus 192,flac 24/192,flac 16/44.1,flac,mp3,m4a,aac,ogg,opus
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
    format = [%%(levelname)s|%%(module)s|L%%(lineno)d] %%(asctime)s: %%(message)s
    datefmt = %%Y-%%m-%%dT%%H:%%M:%%S%%z
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
      after = ["lidarr.service" "slskd.service"];
      wants = ["lidarr.service" "slskd.service"];
      serviceConfig = {
        Type = "oneshot";
        User = "soularr";
        Group = "soularr";
        ExecStartPre = preStartScript;
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
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };
  };
}
