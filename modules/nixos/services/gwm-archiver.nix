# Grapegrower & Winemaker weekly archiver (winetitles.com.au).
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

  # OnFailure=: post the last 50 journal lines to Gotify at high priority.
  notifyFailure = pkgs.writeShellScript "gwm-archiver-notify-failure" ''
    ${readGotifyToken}
    message="$(journalctl -u gwm-archiver.service -n 50 --no-pager 2>/dev/null \
                 | sed 's/[[:cntrl:]]/ /g')"
    ${pkgs.curl}/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
      -F "title=gwm-archiver failed on ${config.networking.hostName}" \
      -F "message=$message" \
      -F "priority=7" >/dev/null || true
  '';

  tc = cfg.triggerConvert;

  # When a new issue lands, wake the conversion host (WOL, LAN broadcast) and
  # kick its marker-convert unit over SSH. The unit runs as root, so SSH uses
  # /root/.ssh (master key → abl030@<host> works). Polkit on the convert host
  # lets abl030 start that one unit without sudo. Fire-and-forget: --no-block
  # returns immediately, the convert host owns the rest (convert + Komga
  # rescan). Best-effort throughout — a failed wake never fails the unit; the
  # convert host's weekly RTC-wake timer is the safety net.
  triggerConvertSnippet = lib.optionalString tc.enable ''
    echo "waking + triggering convert host (${tc.sshTarget})"
    ${pkgs.wakeonlan}/bin/wakeonlan -i ${tc.broadcast} ${tc.mac} >/dev/null 2>&1 || true
    # epi resumes from suspend-to-RAM + tailscale reconnect takes a few s.
    up=0
    for _ in $(seq 1 30); do
      if ${pkgs.openssh}/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=accept-new ${tc.sshTarget} true 2>/dev/null; then
        up=1; break
      fi
      sleep 5
    done
    if [ "$up" = 1 ]; then
      ${pkgs.openssh}/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new ${tc.sshTarget} \
        'systemctl start --no-block marker-convert.service' \
        && echo "marker-convert triggered" \
        || echo "WARN: marker-convert trigger failed (weekly RTC timer will catch up)" >&2
    else
      echo "WARN: convert host unreachable after WOL; weekly RTC timer will catch up" >&2
    fi
  '';

  # OnSuccess=: scan the run's journal for "NEW_ISSUE:" lines emitted by the
  # script when a fresh PDF was downloaded or synthesised. If any, push a
  # single low-priority Gotify with the summary AND wake+trigger the EPUB
  # conversion host. Silent / no-op on weeks with nothing new.
  notifySuccess = pkgs.writeShellScript "gwm-archiver-notify-success" ''
    ${readGotifyToken}
    # Window matches the unit's TimeoutStartSec ceiling so we don't drag in
    # an earlier run's lines if two runs happened within an hour. `|| true`
    # on the grep so the empty-result case (a no-op week) isn't propagated
    # to a unit-level failure under set -eu / pipefail in readGotifyToken.
    new_lines="$(journalctl -u gwm-archiver.service --since='-45min' --no-pager 2>/dev/null \
                   | { grep -E 'NEW_ISSUE:' || true; } \
                   | sed 's/^[^]]*\] //; s/[[:cntrl:]]/ /g')"
    if [ -z "$new_lines" ]; then
      exit 0
    fi
    count="$(printf '%s\n' "$new_lines" | wc -l | tr -d ' ')"
    ${pkgs.curl}/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
      -F "title=GWM archiver picked up $count new issue(s) on ${config.networking.hostName}" \
      -F "message=$new_lines" \
      -F "priority=4" >/dev/null || true
    ${triggerConvertSnippet}
  '';
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
      default = "/mnt/data/Media/Magazines/GAW";
      description = ''
        Destination directory for downloaded magazine PDFs and sidecars.
        Layout: <outDir>/<YYYY>/<MM>_<basename>.{pdf,json}.
        Must be writable by the service user and survive across hosts (typically
        a virtiofs- or NFS-backed media share).
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
        Systemd OnCalendar expression. Default: weekly Sunday 03:30 AWST.
        The script is idempotent; running more often is safe but wasteful
        (~30 min of dead-archive probes per run).
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

    # Notification units run as root (no User=) so they can read the
    # shared homelab gotify/token (mode 0400, root-owned).
    systemd.services.gwm-archiver-notify-failure = {
      description = "Notify Gotify on gwm-archiver failure";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyFailure;
      };
    };

    systemd.services.gwm-archiver-notify-success = {
      description = "Notify Gotify on gwm-archiver successful new-issue pickup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifySuccess;
      };
    };

    systemd.services.gwm-archiver = {
      description = "Archive Grapegrower & Winemaker PDFs from winetitles.com.au";
      after = ["network-online.target"];
      wants = ["network-online.target"];

      unitConfig = {
        OnFailure = ["gwm-archiver-notify-failure.service"];
        OnSuccess = ["gwm-archiver-notify-success.service"];
      };

      # Tools the script shells out to: qpdf (merge), pdfinfo (page counts),
      # exiftool (write PDF metadata). Python stdlib does the rest.
      path = with pkgs; [python3 qpdf poppler-utils exiftool];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        # EnvironmentFile supplies WT_USER + WT_PASS — see secrets/gwm-archiver.env.
        EnvironmentFile = config.sops.secrets."gwm-archiver/env".path;
        Environment = [
          "OUT_ROOT=${cfg.outDir}"
          "SLEEP_SECS=${toString cfg.sleepSecs}"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 -u ${archiveScript}";

        # ~32 min is a comfortable ceiling: ~21 min for the 150 dead-issue
        # fail-fast probes + ~5 min for any actually-new issue.
        TimeoutStartSec = "45min";

        # Hardening — script needs network + writes to cfg.outDir only.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [cfg.outDir];
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
        SyslogIdentifier = "gwm-archiver";
      };
    };

    systemd.timers.gwm-archiver = {
      description = "Weekly GWM archive sweep";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        # Spread the wakeup across an hour so multiple hosts don't all
        # hammer winetitles at the same second on Sundays.
        RandomizedDelaySec = "1h";
      };
    };

    # No homelab.nfsWatchdog wiring: the watchdog auto-restarts dead services,
    # which on a oneshot would re-fire the run. If /mnt/data is stale at the
    # weekly trigger time, the script fails, OnFailure pings Gotify, and the
    # following week's timer picks up cleanly once the mount recovers.
  };
}
