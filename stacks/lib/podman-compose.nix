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

  # Clean up orphaned containers, pods, and health check timers after stack
  # stop/restart. When containers are replaced, stopped containers linger and
  # old systemd health check timers spam "no container with name or ID found".
  stackCleanup = pkgs.writeShellScript "podman-stack-cleanup" ''
    set -euo pipefail
    sleep 2

    # Prune stopped containers and dead pods
    ${podmanBin} container prune -f --filter "until=60s" 2>/dev/null || true
    ${podmanBin} pod prune -f 2>/dev/null || true

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

  mkRunEnvPaths = envFiles:
    lib.concatStringsSep " " (map (env: env.runFile) (normalizeEnvFiles envFiles));

  mkMountRequirements = requiresMounts: let
    merged = [dataRoot] ++ requiresMounts;
  in
    if merged == []
    then {}
    else {RequiresMountsFor = merged;};

  mkExecStartPre = envFiles: preStart: let
    base =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/mkdir -p ${runUserDir}/secrets"
      ];
    decrypt = mkDecryptSteps envFiles;
    chmod =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/chmod 600 ${mkRunEnvPaths envFiles}"
      ];
    chown =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/chown ${user}:${userGroup} ${mkRunEnvPaths envFiles}"
      ];
  in
    base ++ preStart ++ decrypt ++ chmod ++ chown;

  mkExecStartPreUser = envFiles: preStart: let
    base =
      if envFiles == []
      then []
      else [
        "/run/current-system/sw/bin/mkdir -p ${runUserDir}/secrets"
      ];
  in
    base ++ preStart;

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
  }: let
    autoUpdateUnit = "podman-compose@${projectName}";
    podPrune =
      if prunePod
      then [
        # Ensure legacy pod_ containers don't break auto-update.
        "${podmanBin} pod rm -f pod_${projectName} || true"
      ]
      else [];
    recreateIfLabelMismatch = [
      "/run/current-system/sw/bin/sh -lc 'ids=$(${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} -q); if [ -n \"$ids\" ]; then mismatch=$(${podmanBin} inspect -f \"{{.Config.Labels.PODMAN_SYSTEMD_UNIT}}\" $ids 2>/dev/null | /run/current-system/sw/bin/grep -v \"${autoUpdateUnit}.service\" || true); if [ -n \"$mismatch\" ]; then ${podmanBin} rm -f $ids || true; fi; fi'"
    ];
    detectStaleHealth = [
      "/run/current-system/sw/bin/sh -c 'ids=$(${podmanBin} ps -a --filter label=io.podman.compose.project=${projectName} --format \"{{.ID}}\"); for id in \$ids; do health=$(${podmanBin} inspect -f \"{{.State.Health.Status}}\" \$id 2>/dev/null || echo \"none\"); started=$(${podmanBin} inspect -f \"{{.State.StartedAt}}\" \$id 2>/dev/null); if [ \"\$health\" = \"starting\" ] || [ \"\$health\" = \"unhealthy\" ]; then started_clean=\$(echo \"\$started\" | /run/current-system/sw/bin/awk \"{print \\\$1, \\\$2, \\\$3}\"); age_seconds=\$(( \$(date +%%s) - \$(date -d \"\$started_clean\" +%%s) )); if [ \$age_seconds -gt ${toString healthCheckTimeout} ]; then echo \"Removing container \$id with stale health (\$health) - running for \${age_seconds}s (threshold: ${toString healthCheckTimeout}s)\"; ${podmanBin} rm -f \$id; else echo \"Container \$id is \$health but only \${age_seconds}s old - allowing more time (threshold: ${toString healthCheckTimeout}s)\"; fi; fi; done'"
    ];
    baseRestartTriggers =
      lib.unique
      ([
          composeFile
        ]
        ++ (map (env: env.sopsFile) envFiles)
        ++ restartTriggers);
  in {
    networking.firewall.allowedTCPPorts = firewallPorts;
    networking.firewall.allowedUDPPorts = firewallUDPPorts;
    homelab = {
      localProxy.hosts = lib.mkAfter stackHosts;
      monitoring.monitors = lib.mkAfter stackMonitors;
      loki.extraScrapeTargets = lib.mkAfter scrapeTargets;
    };

    systemd.services.${stackName} = {
      inherit description;
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
      # System services must wait for user session and podman socket
      requires = requires ++ ["user@${toString userUid}.service"];
      after = after ++ ["user@${toString userUid}.service"];
      inherit wants;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        PermissionsStartOnly = true;
        Environment = mkEnv projectName (extraEnv ++ ["PODMAN_SYSTEMD_UNIT=${autoUpdateUnit}.service"]);

        ExecStartPre = mkExecStartPre envFiles (podPrune ++ detectStaleHealth ++ recreateIfLabelMismatch ++ preStart);

        ExecStart = "${podmanCompose} ${composeArgs} -f ${composeFile} ${mkEnvArgs envFiles} up -d --wait --remove-orphans";
        ExecStartPost = "+/run/current-system/sw/bin/runuser -u ${user} -- ${stackCleanup}";
        ExecStop = "${podmanCompose} ${composeArgs} -f ${composeFile} ${mkEnvArgs envFiles} stop";
        ExecStopPost = "+/run/current-system/sw/bin/runuser -u ${user} -- ${stackCleanup}";
        ExecReload = "${podmanCompose} ${composeArgs} -f ${composeFile} ${mkEnvArgs envFiles} up -d --wait --remove-orphans";

        Restart = restart;
        RestartSec = restartSec;
        StandardOutput = "journal";
        StandardError = "journal";
      };

      wantedBy = ["multi-user.target"];
    };

    systemd.user.services.${autoUpdateUnit} = {
      description = "Podman compose auto-update unit for ${projectName}";
      restartIfChanged = false;
      after = ["podman.socket"];
      wants = ["podman.socket"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = mkEnv projectName (extraEnv ++ ["PODMAN_SYSTEMD_UNIT=${autoUpdateUnit}.service"]);
        ExecStartPre = mkExecStartPreUser envFiles preStart;
        ExecStart = "${podmanCompose} ${composeArgs} -f ${composeFile} ${mkEnvArgs envFiles} up -d --wait --remove-orphans";
        ExecStop = "${podmanCompose} ${composeArgs} -f ${composeFile} ${mkEnvArgs envFiles} stop";
        ExecReload = "${podmanCompose} ${composeArgs} -f ${composeFile} ${mkEnvArgs envFiles} up -d --wait --remove-orphans";
      };
      wantedBy = ["default.target"];
    };
  };
in {
  inherit mkService;
}
