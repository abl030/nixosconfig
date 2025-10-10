{
  config,
  pkgs,
  ...
}: let
  # ── Per-stack knobs ────────────────────────────────────────
  stackName = "invoices-stack";
  stackDir = "/home/abl030/nixosconfig/docker/invoices";
  encEnv = "/home/abl030/nixosconfig/secrets/secrets/invoices.env"; # SOPS-encrypted
  ageKey = "/root/.config/sops/age/keys.txt"; # your AGE key
  requiresBase = ["docker.service" "network-online.target"];

  # ── Derived (usually no need to touch) ────────────────────────────────────────
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  runEnv = "/run/secrets/${stackName}.env";
  afterBase = requiresBase;
in {
  systemd.services.${stackName} = {
    description = "Invoices Docker Compose Stack";

    restartIfChanged = false;
    reloadIfChanged = true;

    requires = requiresBase;
    after = afterBase;

    serviceConfig = {
      # oneshot pattern for docker compose up -d
      Type = "oneshot";
      RemainAfterExit = true;

      # Where docker-compose.yml lives
      WorkingDirectory = stackDir;

      # Decrypt env → /run (tmpfs) and lock perms before starting
      ExecStartPre = [
        "/run/current-system/sw/bin/mkdir -p /run/secrets"
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runEnv}"
      ];

      # Start / reload with always-pull for :latest images
      ExecStart = "${dockerBin} compose --env-file ${runEnv} up -d --remove-orphans";
      ExecReload = "${dockerBin} compose --env-file ${runEnv} up -d --remove-orphans";

      # Stop the stack
      ExecStop = "${dockerBin} compose down";

      # Auto-retry on failure
      Restart = "on-failure";
      RestartSec = "30s";
    };

    wantedBy = ["multi-user.target"];
  };
}
