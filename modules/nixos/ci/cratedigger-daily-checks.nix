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
          pkgs.nix
          pkgs.openssh
          pkgs.pyright
        ];

        environment = {
          HOME = "/home/abl030";
          XDG_CACHE_HOME = "${stateDir}/cache";
          CRATEDIGGER_AUTOMATION_STATE_DIR = stateDir;
          CRATEDIGGER_MIRROR_URL = "http://192.168.1.35:5200";
        };

        serviceConfig = {
          Type = "oneshot";
          User = "abl030";
          Group = "users";
          ExecStart = "${pkgs.bash}/bin/bash ${runner}";
          TimeoutStartSec = "12h";

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
