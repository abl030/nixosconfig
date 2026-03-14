{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.rtrfm-nowplaying;

  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint;

  serverScript = builtins.path {
    path = ./server.py;
    name = "rtrfm-nowplaying-server.py";
  };

  # Gotify notification script for OnFailure=
  notifyScript = pkgs.writeShellScript "rtrfm-notify-failure" ''
    set -euo pipefail
    token_file="''${GOTIFY_TOKEN_FILE:-${toString gotifyTokenFile}}"
    if [ -z "$token_file" ] || [ ! -r "$token_file" ]; then
      echo "No gotify token file available, skipping notification"
      exit 0
    fi
    raw_token="$(cat "$token_file")"
    if [[ "$raw_token" == GOTIFY_TOKEN=* ]]; then
      token="''${raw_token#GOTIFY_TOKEN=}"
    else
      token="$raw_token"
    fi
    if [ -z "$token" ]; then
      echo "Empty gotify token, skipping notification"
      exit 0
    fi
    # Grab recent journal entries for context
    message="$(journalctl -u rtrfm-nowplaying.service -n 50 --no-pager 2>/dev/null | sed 's/[[:cntrl:]]/ /g')"
    ${pkgs.curl}/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
      -F "title=rtrfm-nowplaying failed on ${config.networking.hostName}" \
      -F "message=$message" \
      -F "priority=5" >/dev/null || true
  '';
in {
  options.homelab.services.rtrfm-nowplaying = {
    enable = lib.mkEnableOption "RTRFM now-playing REST API (Shazam fingerprinting)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8095;
      description = "Port for the HTTP server";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "rtrfm.ablz.au";
      description = "Public hostname for the reverse proxy";
    };
  };

  config = lib.mkIf cfg.enable {
    # Failure notification unit — triggered by OnFailure=
    systemd.services.rtrfm-nowplaying-notify = {
      description = "Notify Gotify on rtrfm-nowplaying failure";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyScript;
        Environment = lib.optionals (gotifyTokenFile != null) [
          "GOTIFY_TOKEN_FILE=${gotifyTokenFile}"
        ];
      };
    };

    systemd.services.rtrfm-nowplaying = {
      description = "RTRFM Now Playing API";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      unitConfig = {
        OnFailure = ["rtrfm-nowplaying-notify.service"];
      };

      startLimitBurst = 5;
      startLimitIntervalSec = 300;

      path = [pkgs.ffmpeg pkgs.songrec];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.python3}/bin/python3 ${serverScript} ${toString cfg.port} /var/lib/rtrfm-nowplaying";
        StateDirectory = "rtrfm-nowplaying";
        Restart = "on-failure";
        RestartSec = 10;

        # Hardening
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;

        # Logging — stdout/stderr → journal
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "rtrfm-nowplaying";
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = cfg.host;
          port = cfg.port;
        }
      ];
      monitoring.monitors = [
        {
          name = "RTRFM Now Playing";
          url = "https://${cfg.host}/health";
        }
      ];
    };
  };
}
