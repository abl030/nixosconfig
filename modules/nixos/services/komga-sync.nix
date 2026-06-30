# Daily Komga metadata sync from JSON sidecars (REST PATCH).
# See docs/wiki/services/komga-sync.md for the field mapping +
# idempotency design notes. Top-level overview at
# docs/wiki/services/magazines.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.komga-sync;
  sendNegativeAlert = import ../lib/negative-alert.nix {inherit config lib pkgs;};

  syncScript = builtins.path {
    path = ../../../scripts/komga-sync.py;
    name = "komga-sync.py";
  };

  notifyFailure = pkgs.writeShellScript "komga-sync-notify-failure" ''
    set -euo pipefail
    ${sendNegativeAlert}
    message="$(journalctl -u komga-sync.service -n 80 --no-pager 2>/dev/null \
                 | sed 's/[[:cntrl:]]/ /g')"
    send_negative_alert "komga-sync failed on ${config.networking.hostName}" "$message" 5
  '';
in {
  options.homelab.services.komga-sync = {
    enable = lib.mkEnableOption "Komga metadata sync from JSON sidecars (daily oneshot)";

    sidecarRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/magazines";
      description = "Root directory whose JSON sidecars are projected into Komga (dedicated single-disk share).";
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
      description = "Send komga-sync failures to RCA, with Gotify fallback";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyFailure;
      };
    };

    systemd.services.komga-sync = {
      description = "Sync Komga book/series metadata from JSON sidecars";
      after = ["network-online.target" "mnt-magazines.mount"];
      wants = ["network-online.target" "mnt-magazines.mount"];

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
