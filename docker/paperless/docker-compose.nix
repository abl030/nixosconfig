{
  config,
  pkgs,
  ...
}: let
  # ── Per-stack knobs ────────────────────────────────────────
  stackName = "paperless-stack";

  # Nix will copy these files to the Nix Store.
  # This removes the dependency on /home/abl030 at runtime.
  composeFile = ./docker-compose.yml;
  encEnv = config.homelab.secrets.sopsFile "paperless.env";

  ageKey = "/root/.config/sops/age/keys.txt";

  # Paperless relies on physical mounts, so we keep mnt-data.mount
  requiresBase = ["docker.service" "network-online.target" "mnt-data.mount"];

  # ── Derived ────────────────────────────────────────────────
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  runEnv = "/run/secrets/${stackName}.env";
  afterBase = requiresBase;
in {
  systemd.services.${stackName} = {
    description = "Paperless Docker Compose Stack";

    restartIfChanged = true;
    reloadIfChanged = false;

    requires = requiresBase;
    after = afterBase;

    serviceConfig = {
      # 'oneshot' is perfect for commands that start a process and then exit.
      Type = "oneshot";
      RemainAfterExit = true;

      # Decrypt env from the Nix store location → /run (tmpfs)
      ExecStartPre = [
        "/run/current-system/sw/bin/mkdir -p /run/secrets"
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runEnv}"
      ];

      # Start using the specific compose file from the Nix Store
      ExecStart = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";

      # Stop the stack
      ExecStop = "${dockerBin} compose -f ${composeFile} down";

      # Reload the service
      ExecReload = "${dockerBin} compose -f ${composeFile} --env-file ${runEnv} up -d --remove-orphans";

      # Restart the service automatically if it fails
      Restart = "on-failure";
      RestartSec = "30s";

      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
