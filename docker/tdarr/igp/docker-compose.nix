{
  config,
  pkgs,
  ...
}: let
  # ── Per-stack knobs ─────────────────────────────────────────
  stackName = "tdarr-igp-stack";
  stackDir = "/home/abl030/nixosconfig/docker/tdarr/igp";

  requiresBase = [
    "docker.service"
    "network-online.target"
    "mnt-data.mount"
  ];

  # ── Derived ────────────────────────────────────────────────
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  afterBase = requiresBase;
in {
  systemd.services.${stackName} = {
    description = "Tdarr IGP Compose Stack";
    restartIfChanged = false;
    reloadIfChanged = true;

    requires = requiresBase;
    after = afterBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = stackDir;

      # Start / reload (remove orphans to keep things tidy)
      ExecStart = "${dockerBin} compose up -d --remove-orphans";
      ExecReload = "${dockerBin} compose up -d --remove-orphans";

      # Stop the stack cleanly
      ExecStop = "${dockerBin} compose down";

      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
