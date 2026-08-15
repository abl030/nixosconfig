{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.ci.cratediggerDailyChecks;
  runner = "${inputs.cratedigger-src}/scripts/daily_flake_update.sh";
  tipRunner = "${inputs.cratedigger-src}/scripts/daily_beets_tip_update.sh";
  stateDir = "/var/lib/cratedigger-daily-checks";
  dailyGhConfigDir = "${stateDir}/daily-gh";
  tipGhConfigDir = "${stateDir}/beets-tip-gh";
  dailyRuntimeDir = "/run/cratedigger-daily-checks";
  dailyScratchDir = "${dailyRuntimeDir}/scratch";
  tipRuntimeDir = "/run/cratedigger-beets-tip-canary";
  tipScratchDir = "${tipRuntimeDir}/scratch";
  dailyWrapperDir = "${dailyRuntimeDir}/wrappers";
  tipWrapperDir = "${tipRuntimeDir}/wrappers";
  timeoutStartSec = "17h";
  ghHostsFile = "/home/abl030/.config/gh/hosts.yml";
  # ONE list for both candidate units: they run the same suite, so they need
  # the same tools. The tip canary used to run three targeted nix builds and
  # carried a shorter list; when it started running the whole suite, the
  # missing jq and openssh failed 17 deploy-tooling targets
  # (tests.test_deploy_pin_script drives scripts/pin_nixosconfig.sh, which
  # shells out to jq, and tests.test_deploy_cycle_verifier drives
  # scripts/verify_cratedigger_cycle.sh, which needs both). Keeping the lists
  # separate is what let the two drift apart in the first place.
  candidatePath = [
    pkgs.bash
    pkgs.coreutils
    pkgs.gh
    pkgs.git
    pkgs.jq
    pkgs.nix
    pkgs.nodejs
    pkgs.openssh
    pkgs.pyright
    pkgs.util-linux
  ];
  dailyCandidatePath = candidatePath;
  tipCandidatePath = candidatePath;
  candidateEnvironmentPath = wrapperDir: path: "${wrapperDir}:${lib.makeBinPath path}";
  candidateWrapperBinds = wrapperDir: [
    "${config.security.wrapperDir}/newuidmap:${wrapperDir}/newuidmap"
    "${config.security.wrapperDir}/newgidmap:${wrapperDir}/newgidmap"
  ];
  sendNegativeAlert = import ../lib/negative-alert.nix {inherit config lib pkgs;};

  prepareGhConfig = name: configDir:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [pkgs.coreutils];
      text = ''
        set -euo pipefail

        # gh currently migrates hosts.yml before serving git's credential
        # helper. Keep the operator's credential source read-only and refresh a
        # service-private copy that gh may safely rewrite before flock runs.
        install -d -m 0700 ${lib.escapeShellArg configDir}
        install -m 0600 ${lib.escapeShellArg ghHostsFile} \
          ${lib.escapeShellArg "${configDir}/hosts.yml"}
      '';
    };
  prepareDailyGhConfig = prepareGhConfig "cratedigger-daily-prepare-gh-config" dailyGhConfigDir;
  prepareTipGhConfig = prepareGhConfig "cratedigger-beets-tip-prepare-gh-config" tipGhConfigDir;

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
          /run/current-system/sw/bin/cratedigger-live-world-audit-tracked
      )"; then
        audit_status=0
      else
        audit_status=$?
      fi

      if ! summary="$(
        ${pkgs.jq}/bin/jq -ce \
          -f ${./scripts/cratedigger-world-audit-protocol.jq} \
          <<<"$audit_json"
      )"; then
        echo "live world audit: invalid tracked JSON report (remote exit $audit_status)" >&2
        exit 1
      fi

      echo "$summary"
      summary_status="$(${pkgs.jq}/bin/jq -r '.status' <<<"$summary")"
      if ((audit_status == 0)) && [[ "$summary_status" =~ ^(clean|tracked_debt)$ ]]; then
        echo "PASS live world audit: known debt is stable or shrinking"
        exit 0
      fi
      if ((audit_status == 1)) && [[ "$summary_status" == unrecognized_violations ]]; then
        echo "FAIL live world audit: new or changed violations (exit $audit_status)" >&2
        exit 1
      fi
      echo "live world audit: exit/status protocol mismatch (remote exit $audit_status)" >&2
      exit 1
    '';
  };

  notifyFailure = pkgs.writeShellScript "cratedigger-daily-checks-notify-failure" ''
    set -euo pipefail
    ${sendNegativeAlert}
    # systemd supplies the failed unit's exact invocation to OnFailure jobs.
    # Do not query the unit's current InvocationID: a manual/concurrent rerun
    # could otherwise make this alert summarize the wrong execution.
    invocation_id="''${MONITOR_INVOCATION_ID:-}"
    if [[ -n "$invocation_id" ]]; then
      journal=(
        ${pkgs.systemd}/bin/journalctl
        -u cratedigger-daily-checks.service
        "_SYSTEMD_INVOCATION_ID=$invocation_id"
        --no-pager
        -o cat
      )
    else
      journal=(
        ${pkgs.systemd}/bin/journalctl
        -u cratedigger-daily-checks.service
        -n 500
        --no-pager
        -o cat
      )
      invocation_id=unavailable
    fi
    message="$("''${journal[@]}" 2>/dev/null \
      | ${pkgs.python3}/bin/python3 \
          ${./scripts/cratedigger-daily-summary.py} \
          --invocation-id "$invocation_id")"
    send_negative_alert \
      "Cratedigger daily unstable checks failed on ${config.networking.hostName}" \
      "$message" 5
  '';

  notifyTipFailure = pkgs.writeShellScript "cratedigger-beets-tip-canary-notify-failure" ''
        set -euo pipefail
        ${sendNegativeAlert}
        invocation_id="''${MONITOR_INVOCATION_ID:-unavailable}"
        if [[ "$invocation_id" == unavailable ]]; then
          journal=(
            ${pkgs.systemd}/bin/journalctl
            -u cratedigger-beets-tip-canary.service
            -n 500
            --no-pager
            -o cat
          )
        else
          journal=(
            ${pkgs.systemd}/bin/journalctl
            -u cratedigger-beets-tip-canary.service
            "_SYSTEMD_INVOCATION_ID=$invocation_id"
            --no-pager
            -o cat
          )
        fi
        message="$("''${journal[@]}" 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -E 'beets tip canary|beetsTip|error:|failed|fatal:' \
          | ${pkgs.coreutils}/bin/tail -n 80 || true)"
        if [[ -z "$message" ]]; then
          message="The tip canary stopped without a classified error line."
        fi
        message="$message

    Full journal:
    journalctl -u cratedigger-beets-tip-canary.service _SYSTEMD_INVOCATION_ID=$invocation_id --no-pager"
        send_negative_alert \
          "Cratedigger Beets tip canary failed on ${config.networking.hostName}" \
          "$message" 5
  '';
in {
  options.homelab.ci.cratediggerDailyChecks.enable =
    lib.mkEnableOption "daily Cratedigger compatibility checks against current nixpkgs unstable";

  config = lib.mkIf cfg.enable {
    # The generated fuzz burst deliberately keeps every active target and its
    # isolated evidence on tmpfs.  The queue has outgrown systemd's default
    # 25%-of-RAM /run ceiling (5.5 GiB on doc1), so make the tested capacity an
    # explicit host invariant rather than allowing a late ENOSPC cascade.
    boot.runSize = "12G";

    assertions = [
      {
        assertion = config.boot.runSize == "12G";
        message = "cratedigger daily checks require a 12G /run tmpfs ceiling";
      }
      {
        assertion = builtins.pathExists runner;
        message = "cratedigger-src must provide scripts/daily_flake_update.sh";
      }
      {
        assertion = builtins.pathExists tipRunner;
        message = "cratedigger-src must provide scripts/daily_beets_tip_update.sh";
      }
      {
        assertion =
          config.systemd.services.cratedigger-daily-checks.serviceConfig.RestrictSUIDSGID
          == false;
        message = "cratedigger daily checks must permit the setgid permission contract";
      }
      {
        assertion =
          config.systemd.services.cratedigger-daily-checks.environment.GH_CONFIG_DIR
          == dailyGhConfigDir;
        message = "cratedigger daily checks must give gh a private writable config directory";
      }
      {
        assertion =
          lib.elem ghHostsFile
          config.systemd.services.cratedigger-daily-checks.serviceConfig.BindReadOnlyPaths;
        message = "cratedigger daily checks must retain the read-only operator GitHub credential source";
      }
      {
        assertion =
          config.systemd.services.cratedigger-beets-tip-canary.environment.CRATEDIGGER_AUTOMATION_STATE_DIR
          == stateDir;
        message = "Beets tip canary must share the Cratedigger daily-checks serialization state";
      }
      {
        assertion =
          config.systemd.services.cratedigger-daily-checks.environment.GH_CONFIG_DIR
          != config.systemd.services.cratedigger-beets-tip-canary.environment.GH_CONFIG_DIR;
        message = "daily and tip candidates must not race on a writable gh config directory";
      }
      {
        assertion =
          config.systemd.services.cratedigger-daily-checks.environment.XDG_RUNTIME_DIR
          != config.systemd.services.cratedigger-beets-tip-canary.environment.XDG_RUNTIME_DIR;
        message = "daily and tip candidates must not share a runtime directory";
      }
      {
        assertion =
          config.systemd.services.cratedigger-daily-checks.serviceConfig.TimeoutStartSec
          == timeoutStartSec
          && config.systemd.services.cratedigger-beets-tip-canary.serviceConfig.TimeoutStartSec
          == timeoutStartSec;
        message = "daily and tip candidates must budget peer lock wait plus their own run window";
      }
      {
        assertion =
          lib.elem pkgs.util-linux config.systemd.services.cratedigger-daily-checks.path
          && lib.elem pkgs.util-linux config.systemd.services.cratedigger-beets-tip-canary.path;
        message = "daily and tip candidates must provide flock through util-linux";
      }
      {
        assertion =
          config.systemd.services.cratedigger-daily-checks.environment.PATH
          == candidateEnvironmentPath dailyWrapperDir dailyCandidatePath
          && config.systemd.services.cratedigger-beets-tip-canary.environment.PATH
          == candidateEnvironmentPath tipWrapperDir tipCandidatePath
          && lib.elem "/run/wrappers" config.systemd.services.cratedigger-daily-checks.serviceConfig.InaccessiblePaths
          && lib.elem "/run/wrappers" config.systemd.services.cratedigger-beets-tip-canary.serviceConfig.InaccessiblePaths
          && lib.all
          (bind: lib.elem bind config.systemd.services.cratedigger-daily-checks.serviceConfig.BindReadOnlyPaths)
          (candidateWrapperBinds dailyWrapperDir)
          && lib.all
          (bind: lib.elem bind config.systemd.services.cratedigger-beets-tip-canary.serviceConfig.BindReadOnlyPaths)
          (candidateWrapperBinds tipWrapperDir)
          && !config.systemd.services.cratedigger-daily-checks.serviceConfig.NoNewPrivileges
          && !config.systemd.services.cratedigger-beets-tip-canary.serviceConfig.NoNewPrivileges;
        message = "candidate suites must expose only the subordinate-ID wrappers";
      }
      {
        assertion =
          config.systemd.timers.cratedigger-beets-tip-canary.timerConfig.OnCalendar
          != config.systemd.timers.cratedigger-daily-checks.timerConfig.OnCalendar;
        message = "Beets tip canary must be staggered from the Nixpkgs candidate timer";
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

      cratedigger-beets-tip-canary-notify-failure = {
        description = "Send Cratedigger Beets tip-canary failures to RCA, with Gotify fallback";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = notifyTipFailure;
        };
      };

      cratedigger-daily-checks = {
        description = "Test Cratedigger against current nixpkgs unstable";
        wants = ["network-online.target"];
        after = ["network-online.target"];
        unitConfig.OnFailure = ["cratedigger-daily-checks-notify-failure.service"];

        path = dailyCandidatePath;

        environment = {
          HOME = "/home/abl030";
          GH_CONFIG_DIR = dailyGhConfigDir;
          XDG_CACHE_HOME = "${stateDir}/cache";
          XDG_RUNTIME_DIR = dailyScratchDir;
          CRATEDIGGER_AUTOMATION_STATE_DIR = stateDir;
          CRATEDIGGER_MIRROR_URL = "http://192.168.1.43:5200";
          # The Beets authority fixtures use unshare --map-auto. NixOS exposes
          # the setuid newuidmap/newgidmap helpers only through wrapperDir.
          PATH = lib.mkForce (candidateEnvironmentPath dailyWrapperDir dailyCandidatePath);
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
          ExecStartPre = "${prepareDailyGhConfig}/bin/cratedigger-daily-prepare-gh-config";
          ExecStart = "${pkgs.bash}/bin/bash ${runner}";
          # Always run against doc2's deployed revision after the candidate
          # runner exits. The "+" prefix keeps the fleet SSH identity out of
          # the untrusted candidate checkout's sandbox. A green runner has
          # already committed/pushed before this begins, while this command's
          # nonzero status still makes the same unit and alert path red.
          ExecStopPost = "+${liveWorldAudit}/bin/cratedigger-daily-live-world-audit";
          # 4h maximum tip-peer lock wait + 12h own Nixpkgs candidate + 1h buffer.
          TimeoutStartSec = timeoutStartSec;
          TimeoutStopSec = "5min";

          StateDirectory = "cratedigger-daily-checks";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "cratedigger-daily-checks";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";

          BindReadOnlyPaths =
            [
              ghHostsFile
              "/home/abl030/.gitconfig"
              "/home/abl030/.ssh/id_ed25519_git_sign"
            ]
            ++ candidateWrapperBinds dailyWrapperDir;
          InaccessiblePaths = [
            "-/run/credentials"
            "-/run/secrets"
            "/run/wrappers"
          ];
          # newuidmap/newgidmap must acquire their NixOS wrapper privileges to
          # install only this user's configured subordinate-ID ranges. Hide the
          # host wrapper directory and bind only those two helpers into the
          # service-private runtime directory; in particular, do not expose the
          # host's passwordless sudo wrapper while NoNewPrivileges is disabled.
          NoNewPrivileges = false;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectHome = "tmpfs";
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          # The candidate suite asserts the production beets tree's setgid
          # contract (02775). This non-root service must be able to exercise
          # that invariant rather than strip the bit first.
          RestrictSUIDSGID = false;
          # Production-depth PostgreSQL fuzz targets can collectively exceed the
          # host's 12 GiB shared /run tmpfs. Keep test scratch RAM-backed, but
          # isolate it from host runtime state and cap it at half of this 32 GiB
          # host's RAM. Mount a child rather than RuntimeDirectory itself:
          # systemd's runtime-directory bind otherwise hides the private mount.
          # Numeric ownership matches doc1's established operator identity and is
          # required because tmpfs is otherwise root:root despite User=abl030.
          # The explicit inode ceiling exceeds both the old shared /run ceiling
          # and the first private ceiling: 1,048,576 inodes still exhausted at
          # 985,571 sampled used while 3.32 GiB remained under the byte ceiling.
          # Ten million was exercised by the 60-worker/24-PostgreSQL fuzz
          # scheduler; it remains only a ceiling, leaving metadata allocation
          # proportional to actual files.
          # Size and inode limits are ceilings, not eager reservations.
          TemporaryFileSystem = [
            "/mnt"
            "${dailyScratchDir}:rw,size=16G,nr_inodes=10000000,mode=0700,uid=1000,gid=100"
          ];

          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "cratedigger-daily-checks";
        };
      };

      # This has no deployment authority: it advances only the checks-only
      # upstream tip lock in a disposable checkout. The production Beets
      # package remains supplied by services.cratedigger.beets.runtime.package.
      cratedigger-beets-tip-canary = {
        description = "Check Cratedigger against upstream Beets tip";
        wants = ["network-online.target"];
        after = ["network-online.target"];
        unitConfig.OnFailure = ["cratedigger-beets-tip-canary-notify-failure.service"];

        path = tipCandidatePath;

        environment = {
          HOME = "/home/abl030";
          GH_CONFIG_DIR = tipGhConfigDir;
          XDG_CACHE_HOME = "${stateDir}/beets-tip-cache";
          XDG_RUNTIME_DIR = tipScratchDir;
          CRATEDIGGER_AUTOMATION_STATE_DIR = stateDir;
          NIX_CONFIG = "experimental-features = nix-command flakes";
          NIX_PATH = "nixpkgs=${pkgs.path}";
          PATH = lib.mkForce (candidateEnvironmentPath tipWrapperDir tipCandidatePath);
        };

        serviceConfig = {
          Type = "oneshot";
          User = "abl030";
          Group = "users";
          ExecStartPre = "${prepareTipGhConfig}/bin/cratedigger-beets-tip-prepare-gh-config";
          ExecStart = "${pkgs.bash}/bin/bash ${tipRunner}";
          # 12h maximum daily-peer lock wait + 4h own tip candidate + 1h buffer.
          TimeoutStartSec = timeoutStartSec;

          StateDirectory = "cratedigger-daily-checks";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "cratedigger-beets-tip-canary";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";

          BindReadOnlyPaths =
            [
              ghHostsFile
              "/home/abl030/.gitconfig"
              "/home/abl030/.ssh/id_ed25519_git_sign"
            ]
            ++ candidateWrapperBinds tipWrapperDir;
          InaccessiblePaths = [
            "-/run/credentials"
            "-/run/secrets"
            "/run/wrappers"
          ];
          # newuidmap/newgidmap must acquire their NixOS wrapper privileges to
          # install only this user's configured subordinate-ID ranges. Hide all
          # other host wrappers while NoNewPrivileges is disabled.
          NoNewPrivileges = false;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectHome = "tmpfs";
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictSUIDSGID = false;
          # The tip canary now runs the whole deterministic suite, not three
          # targeted nix builds, so it needs the same RAM-backed private
          # scratch the Nixpkgs candidate has: the suite allocates roughly a
          # dozen ephemeral PostgreSQL clusters, and XDG_RUNTIME_DIR is what
          # scripts/test_tmpfs.sh roots TMPDIR under. Without this the
          # clusters land on the host's shared 12 GiB /run alongside live
          # runtime state. Same ceiling and shape as the Nixpkgs unit; the
          # two never overlap (a shared flock plus a 13h timer stagger), and
          # a tmpfs ceiling is not an eager reservation. Mount a child rather
          # than RuntimeDirectory itself, or systemd's runtime-directory bind
          # hides the private mount.
          TemporaryFileSystem = [
            "/mnt"
            "${tipScratchDir}:rw,size=16G,nr_inodes=10000000,mode=0700,uid=1000,gid=100"
          ];

          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "cratedigger-beets-tip-canary";
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

    systemd.timers.cratedigger-beets-tip-canary = {
      description = "Run Cratedigger upstream Beets tip canary daily";
      wantedBy = ["timers.target"];
      timerConfig = {
        # The Nixpkgs candidate can use its full 12-hour window from 05:05.
        # Keep the independent tip runner outside that window; both runners
        # additionally flock the shared state directory before mutating a lock.
        OnCalendar = "*-*-* 18:05:00 Australia/Perth";
        Persistent = true;
        AccuracySec = "1min";
      };
    };
  };
}
