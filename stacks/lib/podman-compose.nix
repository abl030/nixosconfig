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

  normalizeLegacyEnvPath = legacyPath:
    if legacyPath == null
    then null
    else lib.replaceStrings ["/run/user/%U"] [runUserDir] legacyPath;

  mkMountRequirements = requiresMounts: let
    merged = [dataRoot] ++ requiresMounts;
  in
    if merged == []
    then {}
    else {RequiresMountsFor = merged;};

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
    restart ? "no",
    restartSec ? "30s",
    firewallPorts ? [],
    firewallUDPPorts ? [],
    restartTriggers ? [],
    scrapeTargets ? [],
    healthCheckTimeout ? 90,
    startupTimeoutSeconds ? 120,
  }: let
    userServiceName = stackName;
    envPathListFile = "${runUserDir}/secrets/${stackName}.env-paths";
    envFileSpecs =
      lib.imap0
      (
        idx: env: let
          legacyRunFile = normalizeLegacyEnvPath (env.runFile or null);
          secretName =
            env.secretName
            or "containers/${stackName}/${toString idx}-${builtins.baseNameOf (env.runFile or "env")}";
        in
          env
          // {
            inherit legacyRunFile secretName;
            nativeRunFile = env.nativeRunFile or config.sops.secrets.${secretName}.path;
          }
      )
      envFiles;
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
        ++ (map (env: env.sopsFile) (lib.filter (env: env ? sopsFile) envFileSpecs))
        ++ restartTriggers);
    stackSecrets = lib.listToAttrs (map (env: {
        name = env.secretName;
        value = {
          inherit (env) sopsFile;
          format = env.sopsFormat or "dotenv";
          owner = user;
          group = userGroup;
          mode = env.mode or "0400";
        };
      })
      (lib.filter (env: env ? sopsFile) envFileSpecs));
    resolveEnvPathsScript = pkgs.writeShellScript "resolve-env-paths-${projectName}" ''
      set -euo pipefail

      /run/current-system/sw/bin/mkdir -p ${runUserDir}/secrets
      env_tmp="$(${pkgs.coreutils}/bin/mktemp)"
      cleanup() {
        /run/current-system/sw/bin/rm -f "$env_tmp"
      }
      trap cleanup EXIT

      append_env_file() {
        local native_path="$1"
        local fallback_path="$2"
        local secret_name="$3"

        if [[ -r "$native_path" ]]; then
          printf "%s\n" "$native_path" >> "$env_tmp"
          return
        fi

        if [[ -n "$fallback_path" && -r "$fallback_path" ]]; then
          echo "WARNING: using compatibility fallback env path for $secret_name: $fallback_path (native missing: $native_path)" >&2
          printf "%s\n" "$fallback_path" >> "$env_tmp"
          return
        fi

        echo "ERROR: missing required secret env file for $secret_name (native: $native_path${"$"}{fallback_path:+, fallback: $fallback_path})" >&2
        exit 1
      }

      ${
        lib.concatMapStringsSep "\n"
        (
          env: ''append_env_file ${lib.escapeShellArg env.nativeRunFile} ${lib.escapeShellArg (env.legacyRunFile or "")} ${lib.escapeShellArg env.secretName}''
        )
        envFileSpecs
      }

      /run/current-system/sw/bin/mv "$env_tmp" ${envPathListFile}
      /run/current-system/sw/bin/chmod 600 ${envPathListFile}
    '';
    resolveEnvPaths = lib.optional (envFileSpecs != []) "${resolveEnvPathsScript}";
    composeWithSystemdLabelScript = pkgs.writeShellScript "compose-with-systemd-label-${projectName}" ''
      set -euo pipefail

      mode="$1"
      shift

      env_args=()
      if [ -r ${envPathListFile} ]; then
        while IFS= read -r env_file; do
          [ -n "$env_file" ] || continue
          env_args+=(--env-file "$env_file")
        done < ${envPathListFile}
      fi

      override_file="$(/run/current-system/sw/bin/mktemp)"
      cleanup() {
        /run/current-system/sw/bin/rm -f "$override_file"
      }
      trap cleanup EXIT

      printf "services:\n" > "$override_file"
      ${podmanCompose} ${composeArgs} -f ${composeFile} "''${env_args[@]}" config --services \
        | while read -r svc; do
          [ -n "$svc" ] || continue
          printf "  %s:\n    labels:\n      PODMAN_SYSTEMD_UNIT: \"%s.service\"\n" "$svc" "${userServiceName}" >> "$override_file"
        done

      case "$mode" in
        up)
          exec ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" "''${env_args[@]}" up -d --remove-orphans "$@"
          ;;
        update)
          ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" "''${env_args[@]}" pull "$@"
          exec ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" "''${env_args[@]}" up -d --remove-orphans "$@"
          ;;
        reload)
          exec ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" "''${env_args[@]}" up -d --remove-orphans "$@"
          ;;
        stop)
          exec ${podmanCompose} ${composeArgs} -f ${composeFile} -f "$override_file" "''${env_args[@]}" stop "$@"
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
      containers.stackUnits = lib.mkAfter ["${userServiceName}.service"];
      containers.stackUpdateUnits = lib.mkAfter ["${userServiceName}-update.service"];
    };
    sops.secrets = stackSecrets;

    # User compose services: stack lifecycle + image update helper (runs as rootless user)
    home-manager.users.${user}.systemd.user.services = {
      ${userServiceName} = {
        Unit =
          {
            Description = description;
            After = ["podman.socket"] ++ after;
            Wants = ["podman.socket"] ++ wants;
            Requires = requires;
            X-Restart-Triggers = baseRestartTriggers;
          }
          // mkMountRequirements requiresMounts;

        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "${toString startupTimeoutSeconds}s";
          Environment = mkEnv projectName (extraEnv ++ ["PODMAN_SYSTEMD_UNIT=${userServiceName}.service"]);

          ExecStartPre =
            resolveEnvPaths
            ++ detectStaleHealth
            ++ podPrune
            ++ recreateIfLabelMismatch
            ++ preStart;

          ExecStart = "${composeWithSystemdLabelScript} up";
          ExecStartPost = [
            "${stackCleanupSimplified}"
          ];
          ExecStop = "${composeWithSystemdLabelScript} stop";
          ExecStopPost = "${stackCleanupSimplified}";
          ExecReload = "${composeWithSystemdLabelScript} reload";

          Restart = restart;
          RestartSec = restartSec;
          StandardOutput = "journal";
          StandardError = "journal";
        };

        Install = {
          WantedBy = ["default.target"];
        };
      };

      "${userServiceName}-update" = {
        Unit =
          {
            Description = "${description} (image update)";
            After = ["podman.socket"] ++ after;
            Wants = ["podman.socket"] ++ wants;
            Requires = requires;
          }
          // mkMountRequirements requiresMounts;

        Service = {
          Type = "oneshot";
          TimeoutStartSec = "${toString startupTimeoutSeconds}s";
          Environment = mkEnv projectName (extraEnv ++ ["PODMAN_SYSTEMD_UNIT=${userServiceName}.service"]);
          ExecStartPre = resolveEnvPaths ++ preStart;
          ExecStart = "${composeWithSystemdLabelScript} update";
          StandardOutput = "journal";
          StandardError = "journal";
        };
      };
    };
  };
in {
  inherit mkService;
}
