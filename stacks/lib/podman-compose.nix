{
  config,
  lib,
  pkgs,
}: let
  inherit (config.homelab) user userHome;
  inherit (config.homelab.containers) dataRoot;
  userUid = let
    uid = config.users.users.${user}.uid or null;
  in
    if uid == null
    then 1000
    else uid;
  userGroup = config.users.users.${user}.group or "users";
  runUserDir = "/run/user/${toString userUid}";
  podmanBin = "${pkgs.podman}/bin/podman";
  podmanCompose = "${podmanBin} compose";
  sopsBin = "${pkgs.sops}/bin/sops";
  ageKey = "${userHome}/.config/sops/age/keys.txt";
  sopsDecryptScript = pkgs.writeShellScript "podman-sops-decrypt" ''
    set -euo pipefail
    out="$1"
    in="$2"
    if [[ -r /var/lib/sops-nix/key.txt ]]; then
      exec /run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt ${sopsBin} -d --output "$out" "$in"
    fi
    if [[ -f "${ageKey}" ]]; then
      exec /run/current-system/sw/bin/env SOPS_AGE_KEY_FILE="${ageKey}" ${sopsBin} -d --output "$out" "$in"
    fi
    echo "No sops identity found (expected /var/lib/sops-nix/key.txt, ${ageKey}, or /etc/ssh/ssh_host_ed25519_key)" >&2
    exit 1
  '';

  # Clean up orphaned health check timers after stack stop/restart.
  # Container/pod pruning is redundant with global timer.
  stackCleanupSimplified = pkgs.writeShellScript "podman-stack-cleanup" ''
    set -euo pipefail

    # Clean up orphaned health check timers
    active_ids=$(${podmanBin} ps -q 2>/dev/null | tr '\n' '|')
    active_ids="''${active_ids%|}"
    if [ -z "$active_ids" ]; then
      active_ids="NONE"
    fi
    /run/current-system/sw/bin/systemctl --user list-units --plain --no-legend --type=timer \
      | /run/current-system/sw/bin/grep -E '^[0-9a-f]{64}-' \
      | /run/current-system/sw/bin/awk '{print $1}' \
      | while read -r timer; do
          cid="''${timer%%-*}"
          if ! echo "$cid" | /run/current-system/sw/bin/grep -qE "^($active_ids)"; then
            /run/current-system/sw/bin/systemctl --user stop "$timer" 2>/dev/null || true
          fi
        done
    /run/current-system/sw/bin/systemctl --user reset-failed 2>/dev/null || true
  '';

  normalizeEnvFiles = envFiles:
    map
    (env:
      env
      // {
        runFile = lib.replaceStrings ["/run/user/%U"] [runUserDir] env.runFile;
      })
    envFiles;

  mkEnvArgs = envFiles:
    lib.concatStringsSep " " (map (env: "--env-file ${env.runFile}") (normalizeEnvFiles envFiles));

  mkDecryptSteps = envFiles:
    map
    (env: ''${sopsDecryptScript} ${env.runFile} ${env.sopsFile}'')
    (normalizeEnvFiles envFiles);

  mkMountRequirements = requiresMounts: let
    merged = [dataRoot] ++ requiresMounts;
  in
    if merged == []
    then {}
    else {RequiresMountsFor = merged;};

  # Generate chmod commands for all decrypted env files
  mkChmodSteps = envFiles:
    map
    (env: "/run/current-system/sw/bin/chmod 600 ${env.runFile}")
    (normalizeEnvFiles envFiles);

  # Generate chown commands for all decrypted env files
  mkChownSteps = envFiles:
    map
    (env: "/run/current-system/sw/bin/chown ${user}:${userGroup} ${env.runFile}")
    (normalizeEnvFiles envFiles);

  # Generate env file existence checks with retry
  mkEnvFileChecks = envFiles:
    map
    (
      env: let
        envFileName = builtins.baseNameOf env.runFile;
        waitScript = pkgs.writeShellScript "wait-for-env-file-${lib.strings.sanitizeDerivationName envFileName}" ''
          max_attempts=30
          attempt=0
          while [ ! -f "${env.runFile}" ]; do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge "$max_attempts" ]; then
              echo "Timeout waiting for ${env.runFile}"
              exit 1
            fi
            sleep 1
          done
        '';
      in "${waitScript}"
    )
    (normalizeEnvFiles envFiles);

  mkEnv = projectName: extraEnv:
    [
      "COMPOSE_PROJECT_NAME=${projectName}"
      "DATA_ROOT=${dataRoot}"
      "HOME=${userHome}"
      "XDG_RUNTIME_DIR=${runUserDir}"
      "PATH=/run/current-system/sw/bin:/run/wrappers/bin"
      # Connect to user's rootless podman socket from system service
      "CONTAINER_HOST=unix://${runUserDir}/podman/podman.sock"
    ]
    ++ extraEnv;

  mkService = {
    stackName,
    description,
    projectName,
    composeFile,
    stackHosts ? [],
    stackMonitors ? [],
    envFiles ? [],
    extraEnv ? [],
    preStart ? [],
    requiresMounts ? [],
    after ? [],
    wants ? [],
    requires ? [],
    composeArgs ? "",
    prunePod ? true,
    restart ? "on-failure",
    restartSec ? "30s",
    firewallPorts ? [],
    firewallUDPPorts ? [],
    restartTriggers ? [],
    scrapeTargets ? [],
    healthCheckTimeout ? 90,
    startupTimeoutSeconds ? 300,
  }: let
    userServiceName = stackName;
    secretsServiceName = "${stackName}-secrets";
    podPrune =
      if prunePod
      then [
        # Ensure legacy pod_ containers don't break auto-update.
        "${podmanBin} pod rm -f pod_${projectName} || true"
      ]
      else [];
    recreateIfLabelMismatchScript = pkgs.writeShellScript "recreate-if-label-mismatch-${projectName}" ''
      set -euo pipefail

      ids=$(
        {
          ${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} -q
          ${podmanBin} ps -a --filter label=com.docker.compose.project=${projectName} -q
        } | /run/current-system/sw/bin/awk 'NF' | /run/current-system/sw/bin/sort -u
      )
      if [ -z "$ids" ]; then
        exit 0
      fi

      mismatch=$(${podmanBin} inspect -f "{{.Config.Labels.PODMAN_SYSTEMD_UNIT}}" $ids 2>/dev/null \
        | /run/current-system/sw/bin/grep -v "^${userServiceName}\.service$" || true)

      if [ -n "$mismatch" ]; then
        ${podmanBin} rm -f --depend $ids
      fi
    '';
    recreateIfLabelMismatch = [
      "${recreateIfLabelMismatchScript}"
    ];
    detectStaleHealthScript = pkgs.writeShellScript "detect-stale-health-${projectName}" ''
      set -euo pipefail

      ids=$(
        {
          ${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format "{{.ID}}"
          ${podmanBin} ps -a --filter label=com.docker.compose.project=${projectName} --format "{{.ID}}"
        } | /run/current-system/sw/bin/awk 'NF' | /run/current-system/sw/bin/sort -u
      )

      if [ -z "$ids" ]; then
        echo "No existing containers found for project ${projectName} during stale health check"
        exit 0
      fi

      echo "Checking stale health for project ${projectName}; container ids: $ids"
      for id in $ids; do
        health=$(${podmanBin} inspect -f "{{.State.Health.Status}}" "$id" 2>/dev/null || echo "none")
        started=$(${podmanBin} inspect -f "{{.State.StartedAt}}" "$id" 2>/dev/null)
        if [ "$health" = "starting" ] || [ "$health" = "unhealthy" ]; then
          # Podman can emit zone names (e.g. AWST) that GNU date rejects with the full string.
          # Keep the first three fields: date, time(+fractional), numeric UTC offset.
          started_clean=$(echo "$started" | /run/current-system/sw/bin/awk '{print $1, $2, $3}')
          started_epoch=$(date -d "$started_clean" +%s)
          age_seconds=$(( $(date +%s) - started_epoch ))
          if [ "$age_seconds" -gt ${toString healthCheckTimeout} ]; then
            echo "Removing container $id with stale health ($health) - running for ''${age_seconds}s (threshold: ${toString healthCheckTimeout}s)"
            ${podmanBin} rm -f "$id"
          else
            echo "Container $id is $health but only ''${age_seconds}s old - allowing more time (threshold: ${toString healthCheckTimeout}s)"
          fi
        fi
      done
    '';
    detectStaleHealth = [
      "${detectStaleHealthScript}"
    ];
    baseRestartTriggers =
      lib.unique
      ([
          composeFile
        ]
        ++ (map (env: env.sopsFile) envFiles)
        ++ restartTriggers);
    composeWithSystemdLabelScript = pkgs.writeShellScript "compose-with-systemd-label-${projectName}" ''
      set -euo pipefail

      mode="$1"
      shift

      override_file="$(/run/current-system/sw/bin/mktemp)"
      cleanup() {
        /run/current-system/sw/bin/rm -f "$override_file"
      }
      trap cleanup EXIT

      printf "services:\n" > "$override_file"
      ${podmanCompose} ${composeArgs} -f ${composeFile} ${mkEnvArgs envFiles} config --services \
        | while read -r svc; do
          [ -n "$svc" ] || continue
          printf "  %s:\n    labels:\n      PODMAN_SYSTEMD_UNIT: \"%s.service\"\n" "$svc" "${userServiceName}" >> "$override_file"
        done

      case "$mode" in
        up)
          exec ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" ${mkEnvArgs envFiles} up -d --wait --wait-timeout ${toString startupTimeoutSeconds} --remove-orphans "$@"
          ;;
        reload)
          exec ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" ${mkEnvArgs envFiles} up -d --wait --wait-timeout ${toString startupTimeoutSeconds} --remove-orphans "$@"
          ;;
        stop)
          exec ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" ${mkEnvArgs envFiles} stop "$@"
          ;;
        *)
          echo "Unknown mode: $mode" >&2
          exit 2
          ;;
      esac
    '';
  in {
    networking.firewall.allowedTCPPorts = firewallPorts;
    networking.firewall.allowedUDPPorts = firewallUDPPorts;
    homelab = {
      localProxy.hosts = lib.mkAfter stackHosts;
      monitoring.monitors = lib.mkAfter stackMonitors;
      loki.extraScrapeTargets = lib.mkAfter scrapeTargets;
    };

    # System secrets service: SOPS decryption (runs as root)
    systemd.services.${secretsServiceName} = {
      description = "SOPS secrets decryption for ${stackName}";
      restartIfChanged = true;
      restartTriggers = baseRestartTriggers;
      reloadIfChanged = false;

      unitConfig =
        mkMountRequirements requiresMounts
        // {
          # Allow retries after dependency failures - 5 attempts in 5 minutes
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;
        };
      # Must wait for user session before bouncing user service
      requires = requires ++ ["user@${toString userUid}.service"];
      after = after ++ ["user@${toString userUid}.service"];
      inherit wants;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "${toString startupTimeoutSeconds}s";
        Environment = mkEnv projectName extraEnv;

        ExecStartPre =
          ["/run/current-system/sw/bin/mkdir -p ${runUserDir}/secrets"]
          ++ detectStaleHealth
          ++ podPrune
          ++ recreateIfLabelMismatch
          ++ preStart;

        # Decrypt all env files (runs as root with access to /var/lib/sops-nix/key.txt)
        ExecStart =
          if envFiles == []
          then "/run/current-system/sw/bin/true"
          else mkDecryptSteps envFiles;

        # Set permissions and bounce user service
        ExecStartPost =
          mkChmodSteps envFiles
          ++ mkChownSteps envFiles
          ++ [
            "+/run/current-system/sw/bin/runuser -u ${user} -- /run/current-system/sw/bin/env XDG_RUNTIME_DIR=${runUserDir} /run/current-system/sw/bin/systemctl --user restart ${userServiceName}.service"
          ];

        Restart = restart;
        RestartSec = restartSec;
        StandardOutput = "journal";
        StandardError = "journal";
      };

      wantedBy = ["multi-user.target"];
    };

    # User compose service: podman compose lifecycle (runs as rootless user)
    systemd.user.services.${userServiceName} = {
      inherit description;
      restartIfChanged = false;
      after = ["podman.socket"];
      wants = ["podman.socket"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "${toString startupTimeoutSeconds}s";
        Environment = mkEnv projectName (extraEnv ++ ["PODMAN_SYSTEMD_UNIT=${userServiceName}.service"]);

        ExecStartPre = mkEnvFileChecks envFiles ++ detectStaleHealth;

        ExecStart = "${composeWithSystemdLabelScript} up";
        ExecStartPost = "${stackCleanupSimplified}";
        ExecStop = "${composeWithSystemdLabelScript} stop";
        ExecStopPost = "${stackCleanupSimplified}";
        ExecReload = "${composeWithSystemdLabelScript} reload";

        Restart = restart;
        RestartSec = restartSec;
        StandardOutput = "journal";
        StandardError = "journal";
      };
      wantedBy = ["default.target"];
    };
  };
in {
  inherit mkService;
}
