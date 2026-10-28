# homelab.services.whatsapp-archive — receive-only WhatsApp archive on doc2.
#
#   whatsapp-archive          (resident)  whatsmeow linked device -> archive.db
#                                         + media files. Never sends anything.
#   whatsapp-archive-snapshot (daily)     sqlite .backup of archive.db onto
#                                         /mnt/data/Life (kopia offsite set).
#   whatsapp-archive-link     (human)     stop service, pair (QR or code), start.
#   whatsapp-archive-import   (human)     decrypt an Android crypt15 backup with
#                                         wtsexporter and merge full history.
#   whatsapp-sql              (readers)   sqlite3 -readonly on archive.db.
#
# Trust boundary: session/ holds the linked-device keys, which can read AND
# send as the account. It is 0700 to the service user and lives on doc2's
# local disk only (not NFS, not the doc1-shared /mnt/virtio). Readers get the
# `whatsapp-archive` group, which reaches archive.db but not session/.
#
# Linked-device access is against WhatsApp's ToS; receive-only keeps the ban
# risk low. Runbook: docs/wiki/services/whatsapp-archive.md
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.whatsapp-archive;
  pkg = import ../../../nix/pkgs/whatsapp-archive/package.nix {inherit pkgs;};
  user = "whatsapp-archive";
  archiveDb = "${cfg.dataDir}/archive.db";

  # Exit codes from main.go: 3 logged out, 4 client outdated, 5 temporary ban.
  # Restarting cannot fix any of them.
  noRestartCodes = "3 4 5";

  flags = lib.escapeShellArgs [
    "-data-dir"
    cfg.dataDir
    "-media-dir"
    cfg.mediaDir
    "-health-addr"
    "127.0.0.1:${toString cfg.healthPort}"
  ];

  sql = pkgs.writeShellScriptBin "whatsapp-sql" ''
    exec ${pkgs.sqlite}/bin/sqlite3 -readonly ${archiveDb} "$@"
  '';

  link = pkgs.writeShellScriptBin "whatsapp-archive-link" ''
    # Usage: whatsapp-archive-link [-phone +614XXXXXXXX]
    # Without -phone a QR code is drawn; with it, an 8-char pairing code.
    set -u
    sudo systemctl stop whatsapp-archive.service
    sudo -u ${user} ${pkg}/bin/whatsapp-archive link ${flags} "$@"
    rc=$?
    sudo systemctl reset-failed whatsapp-archive.service || true
    sudo systemctl start whatsapp-archive.service
    exit $rc
  '';

  importCmd = pkgs.writeShellScriptBin "whatsapp-archive-import" ''
    # Usage: whatsapp-archive-import DIR KEY
    #   DIR  (outside your 0700 home, e.g. /var/tmp/wa-import) holds msgstore.db.crypt15 (and optionally the WhatsApp Media/
    #        folder, wa.db.crypt15 for contact names), copied off the phone.
    #   KEY  the 64-character end-to-end backup key, or a path to the key file.
    # The service is stopped during the merge; the phone queues new messages.
    set -euo pipefail
    dir=$(realpath "$1")
    key=$2
    cd "$dir"
    media=()
    [ -d Media ] && media=(-m Media)
    contacts=()
    [ -f wa.db.crypt15 ] && contacts=(--wab wa.db.crypt15)
    ${pkgs.whatsapp-chat-exporter}/bin/wtsexporter -a -k "$key" -b msgstore.db.crypt15 \
      "''${media[@]}" "''${contacts[@]}" -j result.json --no-html -o "$dir/out"
    sudo chgrp -R ${user} "$dir"
    sudo chmod -R g+rX "$dir"
    sudo systemctl stop whatsapp-archive.service
    trap 'sudo systemctl start whatsapp-archive.service' EXIT
    sudo -u ${user} ${pkg}/bin/whatsapp-archive import-json ${flags} -json "$dir/result.json" -base "$dir"
    echo "Imported. result.json is plaintext history: delete $dir when satisfied."
  '';

  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = ["@system-service" "~@privileged"];
    CapabilityBoundingSet = "";
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
    # Blank /mnt; bind back only the media + snapshot dir (#257 pattern).
    TemporaryFileSystem = "/mnt";
  };
in {
  options.homelab.services.whatsapp-archive = {
    enable = lib.mkEnableOption "receive-only WhatsApp archive (whatsmeow linked device)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/whatsapp-archive";
      description = "Session keys + archive.db. Local disk only: SQLite on NFS is unsafe and the keys must not leave the host.";
    };

    archiveRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Life/Andy/WhatsApp";
      description = "Backed-up root (kopia offsite) for media files and the daily archive.db snapshot.";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.archiveRoot}/media";
      description = "Where downloaded media is written (YYYY/MM/<message id>.<ext>).";
    };

    healthPort = lib.mkOption {
      type = lib.types.port;
      default = 9884;
      description = "Loopback health endpoint: 200 only while connected and logged in.";
    };

    readers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["abl030"];
      description = "Login users added to the whatsapp-archive group: read archive.db (whatsapp-sql) and run the link/import helpers.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users =
      {
        ${user} = {
          isSystemUser = true;
          group = user;
          home = cfg.dataDir;
          createHome = false;
          # NFS write to /mnt/data goes through the users group (as mailarchive).
          extraGroups = ["users"];
        };
      }
      // lib.genAttrs cfg.readers (_: {extraGroups = [user];});
    users.groups.${user} = {};

    environment.systemPackages = [sql link importCmd pkg pkgs.whatsapp-chat-exporter];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${user} ${user} - -"
      "d ${cfg.dataDir}/session 0700 ${user} ${user} - -"
      "d ${cfg.archiveRoot} 0750 ${user} ${user} - -"
      "d ${cfg.mediaDir} 0750 ${user} ${user} - -"
    ];

    systemd.services.whatsapp-archive = {
      description = "WhatsApp archive (receive-only linked device)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "mnt-data.mount"];
      wants = ["network-online.target"];
      requires = ["mnt-data.mount"];
      # Not linked yet: stay quiet instead of exit-3 looping until someone runs
      # whatsapp-archive-link (which starts the unit itself).
      unitConfig = {
        ConditionPathExists = "${cfg.dataDir}/session/session.db";
        RequiresMountsFor = [cfg.mediaDir];
      };
      serviceConfig =
        {
          Type = "simple";
          User = user;
          Group = user;
          UMask = "0027";
          ExecStart = "${pkg}/bin/whatsapp-archive run ${flags}";
          Restart = "on-failure";
          RestartSec = "30s";
          RestartPreventExitStatus = noRestartCodes;
          BindPaths = [cfg.dataDir cfg.mediaDir];
        }
        // hardening;
    };

    systemd.services.whatsapp-archive-snapshot = {
      description = "WhatsApp archive: snapshot archive.db onto backed-up storage";
      after = ["mnt-data.mount"];
      requires = ["mnt-data.mount"];
      unitConfig = {
        ConditionPathExists = archiveDb;
        RequiresMountsFor = [cfg.archiveRoot];
      };
      serviceConfig =
        {
          Type = "oneshot";
          User = user;
          Group = user;
          UMask = "0027";
          # .backup is consistent while the daemon writes; rename is atomic.
          ExecStart = pkgs.writeShellScript "whatsapp-archive-snapshot" ''
            set -eu
            ${pkgs.sqlite}/bin/sqlite3 -readonly ${archiveDb} ".backup '${cfg.archiveRoot}/archive.db.tmp'"
            mv ${cfg.archiveRoot}/archive.db.tmp ${cfg.archiveRoot}/archive.db
          '';
          BindReadOnlyPaths = [cfg.dataDir];
          BindPaths = [cfg.archiveRoot];
        }
        // hardening;
    };

    systemd.timers.whatsapp-archive-snapshot = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 03:30:00";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };

    homelab.monitoring = {
      # DOWN whenever the socket is not connected+logged in, including the
      # not-yet-linked state (unit condition-skipped -> connection refused).
      monitors = [
        {
          name = "WhatsApp archive";
          url = "http://localhost:${toString cfg.healthPort}/health";
        }
      ];

      errorPatterns = [
        {
          name = "WhatsApp archive needs a human";
          unit = "whatsapp-archive.service";
          pattern = "LOGGED OUT|CLIENT OUTDATED|TEMPORARY BAN";
          severity = "critical";
          summary = "WhatsApp archive stopped: re-link, bump whatsmeow, or wait out a ban";
          threshold = 0;
          description = ''
            The daemon exited with a condition restarting cannot fix.
            LOGGED OUT: the phone unlinked the device or was offline ~14 days;
            run `whatsapp-archive-link` on doc2. CLIENT OUTDATED: run
            scripts/update_whatsapp_archive.sh on doc1 and deploy doc2.
            TEMPORARY BAN: leave it stopped until the expiry in the log.
            See docs/wiki/services/whatsapp-archive.md.
          '';
        }
      ];
    };
  };
}
