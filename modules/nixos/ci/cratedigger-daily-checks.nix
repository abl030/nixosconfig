{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.ci.cratediggerDailyChecks;
  runner = "${inputs.cratedigger-src}/scripts/daily_flake_update.sh";
  stateDir = "/var/lib/cratedigger-daily-checks";
  sendNegativeAlert = import ../lib/negative-alert.nix {inherit config lib pkgs;};

  liveWorldAudit = pkgs.writeShellApplication {
    name = "cratedigger-daily-live-world-audit";
    runtimeInputs = [
      pkgs.jq
      pkgs.openssh
    ];
    text = ''
      set -euo pipefail

      echo ""
      echo "=== live world audit ==="

      audit_status=0
      if audit_json="$(
        ${pkgs.openssh}/bin/ssh \
          -F /dev/null \
          -T \
          -o BatchMode=yes \
          -o ConnectTimeout=30 \
          -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts \
          -o UserKnownHostsFile=/dev/null \
          -o StrictHostKeyChecking=yes \
          -o IdentitiesOnly=yes \
          -i ${lib.escapeShellArg config.sops.secrets."ssh_key_abl030".path} \
          abl030@doc2 \
          sudo --non-interactive \
          /run/current-system/sw/bin/cratedigger-live-world-audit
      )"; then
        audit_status=0
      else
        audit_status=$?
      fi

      if ! summary="$(
        ${pkgs.jq}/bin/jq -ce '
          if (
            (.status | type) == "string"
            and (.counts | type) == "object"
            and (.violations | type) == "array"
          )
          then {
            status,
            counts,
            violations_by_code: (
              [.violations[] | .code]
              | sort
              | group_by(.)
              | map({code: .[0], count: length})
            )
          }
          else error("invalid world-audit report")
          end
        ' <<<"$audit_json"
      )"; then
        echo "live world audit: invalid JSON report (remote exit $audit_status)" >&2
        exit 1
      fi

      echo "$summary"
      if ((audit_status == 0)); then
        echo "PASS live world audit"
      else
        echo "FAIL live world audit (exit $audit_status)" >&2
      fi
      exit "$audit_status"
    '';
  };

  notifyFailure = pkgs.writeShellScript "cratedigger-daily-checks-notify-failure" ''
    set -euo pipefail
    ${sendNegativeAlert}
    message="$(${pkgs.systemd}/bin/journalctl \
      -u cratedigger-daily-checks.service -n 200 --no-pager 2>/dev/null \
      | ${pkgs.gnused}/bin/sed 's/[[:cntrl:]]/ /g')"
    send_negative_alert \
      "Cratedigger daily unstable checks failed on ${config.networking.hostName}" \
      "$message" 5
  '';
in {
  options.homelab.ci.cratediggerDailyChecks.enable =
    lib.mkEnableOption "daily Cratedigger compatibility checks against current nixpkgs unstable";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.pathExists runner;
        message = "cratedigger-src must provide scripts/daily_flake_update.sh";
      }
    ];

    systemd.services = {
      cratedigger-daily-checks-notify-failure = {
        description = "Send Cratedigger daily-check failures to RCA, with Gotify fallback";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = notifyFailure;
        };
      };

      cratedigger-daily-checks = {
        description = "Test Cratedigger against current nixpkgs unstable";
        wants = ["network-online.target"];
        after = ["network-online.target"];
        unitConfig.OnFailure = ["cratedigger-daily-checks-notify-failure.service"];

        path = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gh
          pkgs.git
          pkgs.jq
          pkgs.nix
          pkgs.nodejs
          pkgs.openssh
          pkgs.pyright
        ];

        environment = {
          HOME = "/home/abl030";
          XDG_CACHE_HOME = "${stateDir}/cache";
          CRATEDIGGER_AUTOMATION_STATE_DIR = stateDir;
          CRATEDIGGER_MIRROR_URL = "http://192.168.1.35:5200";
          # ProtectHome hides the user's nix.conf, so enable the client-side
          # flake commands and classic nix-shell lookup explicitly inside this
          # sandboxed unit. Node is also explicit in path because run_tests.sh
          # validates the JavaScript suite before Python discovery.
          NIX_CONFIG = "experimental-features = nix-command flakes";
          NIX_PATH = "nixpkgs=${pkgs.path}";
        };

        serviceConfig = {
          Type = "oneshot";
          User = "abl030";
          Group = "users";
          ExecStart = "${pkgs.bash}/bin/bash ${runner}";
          # Always run against doc2's deployed revision after the candidate
          # runner exits. The "+" prefix keeps the fleet SSH identity out of
          # the untrusted candidate checkout's sandbox. A green runner has
          # already committed/pushed before this begins, while this command's
          # nonzero status still makes the same unit and alert path red.
          ExecStopPost = "+${liveWorldAudit}/bin/cratedigger-daily-live-world-audit";
          TimeoutStartSec = "12h";
          TimeoutStopSec = "5min";

          StateDirectory = "cratedigger-daily-checks";
          StateDirectoryMode = "0700";
          UMask = "0077";

          BindReadOnlyPaths = [
            "/home/abl030/.config/gh/hosts.yml"
            "/home/abl030/.gitconfig"
            "/home/abl030/.ssh/id_ed25519_git_sign"
          ];
          InaccessiblePaths = [
            "-/run/credentials"
            "-/run/secrets"
          ];
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectHome = "tmpfs";
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictSUIDSGID = true;
          TemporaryFileSystem = "/mnt";

          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "cratedigger-daily-checks";
        };
      };
    };

    systemd.timers.cratedigger-daily-checks = {
      description = "Run Cratedigger unstable compatibility checks daily";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 05:05:00 Australia/Perth";
        Persistent = true;
        AccuracySec = "1min";
      };
    };
  };
}
