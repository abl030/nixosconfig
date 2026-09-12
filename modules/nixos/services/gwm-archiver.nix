# Grapegrower & Winemaker weekly pickup and separate weekly archive recovery.
# See docs/wiki/services/gwm-archiver.md for the WordPress download flow,
# slug -> year/month math, qpdf-vs-pdfunite gotcha, OnSuccess/OnFailure
# wiring. Top-level overview at docs/wiki/services/magazines.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.gwm-archiver;
  sendNegativeAlert = import ../lib/negative-alert.nix {inherit config lib pkgs;};

  # Pin the source so flake-eval doesn't churn on unrelated repo edits.
  archiveScript = builtins.path {
    path = ../../../scripts/gwm-archiver.py;
    name = "gwm-archiver.py";
  };

  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint or "";

  # Both hooks below run as root (no User= in their unit), so they can read
  # the shared gotify/token file (mode 0400, root readable). Same pattern as
  # rtrfm-nowplaying — see that module for the canonical version.
  readGotifyToken = ''
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
  '';

  # OnFailure=: send the last 50 journal lines to Hermes RCA first, with direct
  # Gotify as fallback. Success notifications remain direct/user-facing.
  notifyFailure = pkgs.writeShellScript "gwm-archiver-notify-failure" ''
    set -euo pipefail
    ${sendNegativeAlert}
    message="$(journalctl "_SYSTEMD_INVOCATION_ID=$MONITOR_INVOCATION_ID" -n 50 --no-pager 2>/dev/null \
                 | sed 's/[[:cntrl:]]/ /g')"
    send_negative_alert "$MONITOR_UNIT failed on ${config.networking.hostName}" "$message" 7
  '';

  tc = cfg.triggerConvert;

  # When a new issue lands, wake the conversion host (WOL, LAN broadcast) and
  # kick its marker-convert unit over SSH. The unit runs as root, so SSH uses a
  # DEDICATED key (#270): doc2 is keyless and no longer carries the fleet
  # identity. epi's authorized_keys (marker-convert.nix) forces this key to ONLY
  # `systemctl start --no-block marker-convert.service` and nothing else, so a
  # *successful connection IS the trigger* — probe and fire collapse into one
  # (running it twice is harmless: starting an active oneshot is a no-op). Polkit
  # on the convert host grants abl030 that one start. Best-effort throughout — a
  # failed wake never fails the unit; the weekly RTC-wake timer is the safety net.
  triggerConvertSnippet = lib.optionalString tc.enable ''
    echo "waking + triggering convert host (${tc.sshTarget})"
    ${pkgs.wakeonlan}/bin/wakeonlan -i ${tc.broadcast} ${tc.mac} >/dev/null 2>&1 || true
    # epi resumes from suspend-to-RAM + tailscale reconnect takes a few s; retry
    # the forced-command SSH until it lands (each success fires marker-convert).
    triggered=0
    for _ in $(seq 1 30); do
      if ${pkgs.openssh}/bin/ssh -i ${config.sops.secrets."gwm-trigger/key".path} \
           -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=accept-new ${tc.sshTarget} 2>/dev/null; then
        triggered=1; break
      fi
      sleep 5
    done
    if [ "$triggered" = 1 ]; then
      echo "marker-convert triggered"
    else
      echo "WARN: convert host unreachable after WOL; weekly RTC timer will catch up" >&2
    fi
  '';

  # Run on either outcome: a later failure cannot suppress completed issues.
  # Template instances keep MONITOR_* context separate for current/backfill.
  notifySuccess = pkgs.writeShellScript "gwm-archiver-notify-success" ''
    set -euo pipefail
    new_lines="$(journalctl "_SYSTEMD_INVOCATION_ID=$MONITOR_INVOCATION_ID" --no-pager -o cat 2>/dev/null \
                   | { grep -E 'NEW_ISSUE:' || true; } \
                   | sed 's/[[:cntrl:]]/ /g')"
    if [ -z "$new_lines" ]; then
      exit 0
    fi
    # Conversion must not depend on Gotify credentials or availability.
    ${triggerConvertSnippet}
    ${readGotifyToken}
    count="$(printf '%s\n' "$new_lines" | wc -l | tr -d ' ')"
    ${pkgs.curl}/bin/curl -fsS --connect-timeout 10 --max-time 30 -X POST "${gotifyUrl}/message?token=$token" \
      -F "title=GWM archiver picked up $count issue(s) on ${config.networking.hostName}" \
      -F "message=$new_lines" \
      -F "priority=4" >/dev/null || true
  '';

  mkArchiveService = mode: let
    name =
      if mode == "current"
      then "gwm-archiver"
      else "gwm-archiver-backfill";
    pickup = "gwm-archiver-notify-success@${name}.service";
  in {
    description = "Archive Grapegrower & Winemaker PDFs (${mode})";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    unitConfig = {
      OnFailure = ["gwm-archiver-notify-failure@${name}.service" pickup];
      OnSuccess = [pickup];
      RequiresMountsFor = [cfg.outDir];
    };
    path = with pkgs; [python3 qpdf poppler-utils exiftool];
    serviceConfig = {
      Type = "oneshot";
      User = cfg.user;
      Group = cfg.group;
      EnvironmentFile = config.sops.secrets."gwm-archiver/env".path;
      Environment = [
        "OUT_ROOT=${cfg.outDir}"
        "SLEEP_SECS=${toString cfg.sleepSecs}"
        "ARCHIVE_MODE=${mode}"
      ];
      ExecStart = "${pkgs.python3}/bin/python3 -u ${archiveScript}";
      TimeoutStartSec = "45min";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      # Hide unrelated host data; fail explicitly if the archive cannot bind.
      TemporaryFileSystem = ["/mnt"];
      BindPaths = [cfg.outDir];
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
      SyslogIdentifier = name;
    };
  };
in {
  options.homelab.services.gwm-archiver = {
    enable = lib.mkEnableOption "Grapegrower & Winemaker PDF archiver (winetitles.com.au)";

    triggerConvert = {
      enable = lib.mkEnableOption ''
        waking + triggering the marker-convert EPUB conversion host after a new
        download. Off by default; enable on the host that runs gwm-archiver
        when a separate box (epi) does the heavy PDF->EPUB conversion'';

      mac = lib.mkOption {
        type = lib.types.str;
        default = "18:c0:4d:65:86:e8";
        description = "WOL target MAC of the conversion host (epi).";
      };

      broadcast = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.255";
        description = "LAN subnet broadcast address for the WOL magic packet.";
      };

      sshTarget = lib.mkOption {
        type = lib.types.str;
        default = "abl030@epimetheus";
        description = ''
          SSH target for the trigger, over Tailscale MagicDNS (stable, unlike
          epi's DHCP LAN IP). The conversion host's polkit lets this user start
          marker-convert.service without sudo.
        '';
      };
    };

    outDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/magazines/GAW";
      description = ''
        Destination directory for downloaded magazine PDFs and sidecars.
        Layout: <outDir>/<YYYY>/<MM>_<basename>.{pdf,json}.
        Must be writable by the service user and survive across hosts. Lives on
        the dedicated single-disk /mnt/magazines NFS share (stable inodes) — NOT
        the multi-disk /mnt/data shfs union, whose synthetic-inode flap used to
        fail this service's ProtectSystem=strict namespace bind with ESTALE
        (226/NAMESPACE). See docs/wiki/infrastructure/unraid-nfs-shfs-estale.md.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "gwm-archiver";
      description = "POSIX user the oneshot runs as. Created by this module unless overridden.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = ''
        POSIX group for the service user. Defaults to `users` so PDFs land
        with media-share-friendly group ownership; override if your NFS share
        expects a different gid.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "Sun *-*-* 03:30:00 Australia/Perth";
      description = ''
        Weekly current-issue check at 03:30 AWST. Completed issues are local
        skips; the missing pre-July-2017 archive has a separate weekly timer.
      '';
    };

    sleepSecs = lib.mkOption {
      type = lib.types.numbers.nonnegative;
      default = 1.0;
      description = "Seconds to sleep between HTTP fetches (politeness to winetitles).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) group;
      description = "GWM archiver oneshot";
    };

    # Credentials file: dotenv with WT_USER and WT_PASS lines.
    #   sops edit secrets/gwm-archiver.env
    sops.secrets."gwm-archiver/env" = {
      sopsFile = config.homelab.secrets.sopsFile "gwm-archiver.env";
      format = "dotenv";
      mode = "0400";
      owner = cfg.user;
    };

    # Dedicated convert-trigger SSH key (#270), only where the trigger runs.
    # doc2 is keyless, so the marker-convert trigger to epi can't ride the fleet
    # identity any more. Root-owned because the notify-success unit (which fires
    # the trigger) runs as root. The matching public half is forced-command-
    # locked on epi in marker-convert.nix; private half is doc2-only sops.
    sops.secrets."gwm-trigger/key" = lib.mkIf tc.enable {
      sopsFile = config.homelab.secrets.sopsFile "gwm-trigger-key";
      format = "binary";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # Notification units run as root (no User=) so they can read the
    # shared homelab gotify/token (mode 0400, root-owned).
    systemd.services."gwm-archiver-notify-failure@" = {
      description = "Send gwm-archiver failures to RCA, with Gotify fallback";
      serviceConfig = {
        Type = "oneshot";
        NoNewPrivileges = true;
        ExecStart = notifyFailure;
      };
    };

    systemd.services."gwm-archiver-notify-success@" = {
      description = "Deliver completed GWM issues regardless of sweep outcome";
      serviceConfig = {
        Type = "oneshot";
        NoNewPrivileges = true;
        ExecStart = notifySuccess;
      };
    };

    systemd.services.gwm-archiver = mkArchiveService "current";
    systemd.services.gwm-archiver-backfill = mkArchiveService "backfill";

    systemd.timers.gwm-archiver = {
      description = "Weekly GWM current-issue pickup";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        # Spread the wakeup across an hour so multiple hosts don't all
        # hammer winetitles at the same second.
        RandomizedDelaySec = "1h";
      };
    };

    systemd.timers.gwm-archiver-backfill = {
      description = "Weekly recovery of missing pre-July-2017 GWM issues";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "Sun *-*-* 05:30:00 Australia/Perth";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # No homelab.nfsWatchdog wiring: the watchdog auto-restarts dead services,
    # which on a oneshot would re-fire the run. The dedicated single-disk
    # /mnt/magazines share has stable inodes, so the shfs-union ESTALE that
    # used to fail the namespace bind should no longer occur; if the mount is
    # genuinely down at a timer trigger, RequiresMountsFor holds the unit
    # until it's up (or the run fails, OnFailure pings Gotify, and the
    # next timer picks up cleanly once it recovers).
  };
}
