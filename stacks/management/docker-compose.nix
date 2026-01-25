{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "management-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "management-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "management.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  inherit (config.homelab.containers) dataRoot;
  dependsOn = ["network-online.target"];
in
  lib.mkMerge [
    (podman.mkService {
      inherit stackName;
      description = "Management Podman Compose Stack";
      projectName = "management";
      inherit composeFile;
      inherit envFiles;
      preStart = [
        "/run/current-system/sw/bin/mkdir -p ${dataRoot}/dozzle/data ${dataRoot}/gotify/data"
        # Use root chown for existing data
        "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/dozzle/data ${dataRoot}/gotify/data"
      ];
      wants = dependsOn;
      after = dependsOn;
      firewallPorts = [8082 8050];
    })
    {
      # Daily 3am restart to clear dozzle server cache of stale containers
      systemd.timers."${stackName}-daily-restart" = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "03:00";
          Persistent = true;
        };
      };

      systemd.services."${stackName}-daily-restart" = {
        description = "Daily restart of ${stackName} to clear dozzle server cache";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart ${stackName}.service";
        };
      };
    }
  ]
