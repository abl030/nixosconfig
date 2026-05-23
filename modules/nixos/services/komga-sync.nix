{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.komga-sync;

  syncScript = builtins.path {
    path = ../../../scripts/komga-sync.py;
    name = "komga-sync.py";
  };

  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint or "";

  notifyFailure = pkgs.writeShellScript "komga-sync-notify-failure" ''
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
    if [ -z "$token" ]; then exit 0; fi
    message="$(journalctl -u komga-sync.service -n 50 --no-pager 2>/dev/null \
                 | sed 's/[[:cntrl:]]/ /g')"
    ${pkgs.curl}/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
      -F "title=komga-sync failed on ${config.networking.hostName}" \
      -F "message=$message" \
      -F "priority=5" >/dev/null || true
  '';
in {
  options.homelab.services.komga-sync = {
    enable = lib.mkEnableOption "Komga metadata sync from JSON sidecars (daily oneshot)";

    sidecarRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Magazines";
      description = "Root directory whose JSON sidecars are projected into Komga.";
    };

    komgaUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://magazines.ablz.au";
      description = "Komga base URL.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "komga-sync";
      description = "Dedicated service user (created by this module).";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:15:00 Australia/Perth";
      # Slots in 45 min after gwm-archiver's weekly Sun 03:30 run so any
      # freshly-downloaded issue plus the Komga DAILY library scan have
      # time to settle.
      description = "Systemd OnCalendar expression for the sync.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = "users";
      description = "Komga metadata sync oneshot";
    };

    sops.secrets."komga-sync/env" = {
      sopsFile = config.homelab.secrets.sopsFile "komga-sync.env";
      format = "dotenv";
      mode = "0400";
      owner = cfg.user;
    };

    systemd.services.komga-sync-notify-failure = {
      description = "Notify Gotify on komga-sync failure";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyFailure;
      };
    };

    systemd.services.komga-sync = {
      description = "Sync Komga book/series metadata from JSON sidecars";
      after = ["network-online.target" "mnt-data.mount"];
      wants = ["network-online.target" "mnt-data.mount"];

      unitConfig.OnFailure = ["komga-sync-notify-failure.service"];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = "users";

        EnvironmentFile = config.sops.secrets."komga-sync/env".path;
        Environment = [
          "KOMGA_URL=${cfg.komgaUrl}"
          "SIDECAR_ROOT=${cfg.sidecarRoot}"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 -u ${syncScript}";

        # Patching 135 books is HTTP-bound; should be done in <5 min.
        # Generous ceiling for a future archive several times larger.
        TimeoutStartSec = "20min";

        # Narrow filesystem visibility, per the Sandbox patterns rule.
        # Sidecars are read-only — komga-sync only reads JSON and writes
        # back via HTTP, never touches the magazine tree.
        TemporaryFileSystem = "/mnt";
        BindReadOnlyPaths = [cfg.sidecarRoot];

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";

        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "komga-sync";
      };
    };

    systemd.timers.komga-sync = {
      description = "Daily Komga metadata sync from JSON sidecars";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "15min";
      };
    };
  };
}
