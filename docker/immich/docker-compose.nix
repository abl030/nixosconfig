{
  config,
  pkgs,
  ...
}: let
  stackName = "immich-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;
  caddyFile = ./Caddyfile;
  tailscaleConfig = ./immich-tailscale-serve.json;

  # Secrets
  encEnv = ../../secrets/secrets/immich.env;
  ageKey = "/root/.config/sops/age/keys.txt";

  # Runtime Env Path
  runEnv = "/run/secrets/${stackName}.env";

  # Dependencies
  requiresBase = ["docker.service" "network-online.target" "mnt-data.mount"];

  # Helper for the docker binary
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
in {
  systemd = {
    # ===================================================================
    # MAIN SERVICE
    # ===================================================================
    services.${stackName} = {
      description = "Immich Docker Compose Stack";
      restartIfChanged = true;
      reloadIfChanged = false;
      requires = requiresBase;
      after = requiresBase;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        # 1. Set Project Name
        # 2. Pass Nix Store paths for Caddyfile and Tailscale JSON
        Environment = [
          "COMPOSE_PROJECT_NAME=immich"
          "CADDY_FILE=${caddyFile}"
          "TAILSCALE_JSON=${tailscaleConfig}"
        ];

        # Decrypt secrets
        ExecStartPre = [
          "/run/current-system/sw/bin/mkdir -p /run/secrets"
          ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
          "/run/current-system/sw/bin/chmod 600 ${runEnv}"
        ];

        # Start
        ExecStart = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";

        # Stop
        ExecStop = "${dockerBin} compose -f ${composeFile} down";

        # Reload
        ExecReload = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";

        Restart = "on-failure";
        RestartSec = "30s";
        StandardOutput = "journal";
        StandardError = "journal";
      };

      wantedBy = ["multi-user.target"];
    };

    # ===================================================================
    # UPDATER SERVICE
    # ===================================================================
    services.immich-updater = {
      description = "Weekly updater for the Immich Docker stack";
      requires = ["${stackName}.service"];
      after = ["${stackName}.service"];

      # We need the same environment variables here so the updater can find the files
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "COMPOSE_PROJECT_NAME=immich"
          "CADDY_FILE=${caddyFile}"
          "TAILSCALE_JSON=${tailscaleConfig}"
        ];
      };

      script = ''
        set -e
        echo "--- [$(date)] Starting scheduled Immich stack update ---"

        # 1. Pull latest images defined in compose file
        ${dockerBin} compose -f ${composeFile} --env-file ${runEnv} pull

        # 2. Restart stack (Build step removed as we now use pre-built Caddy image)
        echo "Restarting stack to apply new images..."
        ${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --force-recreate --remove-orphans

        # 3. Cleanup
        echo "Pruning old Docker images..."
        ${dockerBin} image prune -f

        echo "--- [$(date)] Scheduled Immich stack update complete ---"
      '';
    };

    # ===================================================================
    # UPDATER TIMER
    # ===================================================================
    timers.immich-updater = {
      description = "Timer to trigger weekly Immich stack update";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "Sun 01:00:00";
        Persistent = true;
      };
    };
  };
}
