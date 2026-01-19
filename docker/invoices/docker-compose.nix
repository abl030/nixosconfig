{
  config,
  pkgs,
  ...
}: let
  stackName = "invoices-stack";

  # Nix tracked files
  composeFile = ./docker-compose.yml;
  caddyFile = ./Caddyfile;

  # Secrets (Relative path to this nix file)
  encEnv = config.homelab.secrets.sopsFile "invoices.env";

  ageKey = "/root/.config/sops/age/keys.txt";
  requiresBase = ["docker.service" "network-online.target"];

  # ── Derived ────────────────────────────────────────────────
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  runEnv = "/run/secrets/${stackName}.env";
  afterBase = requiresBase;
in {
  systemd.services.${stackName} = {
    description = "Invoices Docker Compose Stack";
    restartIfChanged = true;
    reloadIfChanged = false;
    requires = requiresBase;
    after = afterBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Set Project Name and pass Caddyfile path
      Environment = [
        "COMPOSE_PROJECT_NAME=invoices"
        "CADDY_FILE=${caddyFile}"
      ];

      # Decrypt env → /run (tmpfs) and lock perms before starting
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
}
