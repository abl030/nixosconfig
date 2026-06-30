{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.rtrfm-nowplaying;
  sendNegativeAlert = import ../../lib/negative-alert.nix {inherit config lib pkgs;};

  serverScript = builtins.path {
    path = ./server.py;
    name = "rtrfm-nowplaying-server.py";
  };

  # RCA-first notification script for OnFailure=, with Gotify fallback.
  notifyScript = pkgs.writeShellScript "rtrfm-notify-failure" ''
    set -euo pipefail
    ${sendNegativeAlert}
    # Grab recent journal entries for context
    message="$(journalctl -u rtrfm-nowplaying.service -n 50 --no-pager 2>/dev/null | sed 's/[[:cntrl:]]/ /g')"
    send_negative_alert "rtrfm-nowplaying failed on ${config.networking.hostName}" "$message" 5
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
      description = "Send rtrfm-nowplaying failures to RCA, with Gotify fallback";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyScript;
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
        # Blank /mnt (#257). State lives in StateDirectory (/var/lib), not
        # under /mnt, so nothing is bound back — TemporaryFileSystem masks
        # the host's /mnt/* tree. A bind/namespace failure here already pages
        # via the OnFailure=rtrfm-nowplaying-notify unit above, so no separate
        # NAMESPACE errorPattern. See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
        TemporaryFileSystem = "/mnt";
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
          inherit (cfg) host;
          inherit (cfg) port;
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
