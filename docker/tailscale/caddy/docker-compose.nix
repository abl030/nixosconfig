{
  config,
  pkgs,
  ...
}: let
  # ── Per-stack knobs ────────────────────────────────────────
  stackName = "caddy-tailscale-stack";

  composeFile = ./docker-compose.yml;
  caddyFile = ./Caddyfile; # <--- NEW: Track the Caddyfile

  encEnv = ../../../secrets/secrets/caddy-tailscale.env;
  ageKey = "/root/.config/sops/age/keys.txt";
  requiresBase = ["docker.service" "network-online.target"];

  # ── Derived ────────────────────────────────────────────────
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  runEnv = "/run/secrets/${stackName}.env";
  afterBase = requiresBase;
in {
  systemd.services.${stackName} = {
    description = "Caddy Tailscale Docker Compose Stack";

    restartIfChanged = true;
    reloadIfChanged = false;

    requires = requiresBase;
    after = afterBase;

    serviceConfig = {
      # ─── ADDED ENVIRONMENT VARIABLES ───
      # 1. Set the project name to prevent collisions
      # 2. Pass the absolute Nix Store path of the Caddyfile to Docker
      Environment = [
        "COMPOSE_PROJECT_NAME=caddy-tailscale"
        "CADDY_FILE=${caddyFile}"
      ];
      # ───────────────────────────────────

      Type = "oneshot";
      RemainAfterExit = true;

      ExecStartPre = [
        "/run/current-system/sw/bin/mkdir -p /run/secrets"
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runEnv}"
      ];

      ExecStart = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";
      ExecStop = "${dockerBin} compose -f ${composeFile} down";
      ExecReload = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";

      Restart = "on-failure";
      RestartSec = "30s";

      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
