{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "igpu-management-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "igpu-management-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "igpu-management.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  dependsOn = ["network-online.target"];
  inherit (config.homelab.containers) dataRoot;
  inherit (config.homelab) user;
  userGroup = config.users.users.${user}.group or "users";
in
  lib.mkMerge [
    {
      systemd.tmpfiles.rules = lib.mkAfter [
        "d ${dataRoot}/dozzle-agent 0750 ${user} ${userGroup} -"
        "d ${dataRoot}/dozzle-agent/data 0750 ${user} ${userGroup} -"
      ];
    }
    (podman.mkService {
      inherit stackName;
      description = "IGPU Management Podman Compose Stack";
      projectName = "igpu";
      inherit composeFile;
      inherit envFiles;
      preStart = [
        "/run/current-system/sw/bin/mkdir -p ${dataRoot}/dozzle-agent/data"
      ];
      wants = dependsOn;
      after = dependsOn;
    })
    {
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -p tcp -s 192.168.1.29 --dport 7007 -j nixos-fw-accept
      '';
    }
    {
      # Daily 3am restart to clear dozzle-agent cache of stale containers
      systemd.timers."${stackName}-daily-restart" = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "03:00";
          Persistent = true;
        };
      };

      systemd.services."${stackName}-daily-restart" = {
        description = "Daily restart of ${stackName} to clear dozzle-agent cache";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart ${stackName}.service";
        };
      };
    }
  ]
