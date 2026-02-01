{
  config,
  lib,
  pkgs,
  ...
}: let
  stackName = "kopia-stack";

  composeFile = builtins.path {
    path = ./docker-compose.yml;
    name = "kopia-docker-compose.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "kopia.env";
  runEnv = "/run/user/%U/secrets/${stackName}.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};
  envFiles = [
    {
      sopsFile = encEnv;
      runFile = runEnv;
    }
  ];

  # Use automount (not mount) for mnt-mum - same as old Docker service
  # Don't include /mnt/mum in requiresMounts as that adds RequiresMountsFor which
  # creates a hard dependency on the actual mount unit instead of automount
  dependsOn = [
    "network-online.target"
    "mnt-data.mount"
    "mnt-mum.automount"
  ];
in
  podman.mkService {
    inherit stackName;
    description = "Kopia Podman Compose Stack";
    projectName = "kopia";
    inherit composeFile;
    inherit envFiles;
    stackHosts = [
      {
        host = "kopiaphotos.ablz.au";
        port = 51515;
      }
      {
        host = "kopiamum.ablz.au";
        port = 51516;
      }
    ];
    stackMonitors = [
      {
        name = "Kopia Photos";
        url = "https://kopiaphotos.ablz.au/";
        acceptedStatusCodes = ["200-299" "300-399" "401"];
      }
      {
        name = "Kopia Mum";
        url = "https://kopiamum.ablz.au/";
        acceptedStatusCodes = ["200-299" "300-399" "401"];
      }
      {
        name = "Kopia Photos Backup";
        type = "json-query";
        url = "http://localhost:51515/api/v1/sources";
        basicAuthUser = "abl030";
        basicAuthPass = "billand1";
        jsonPath = "$count(sources[lastSnapshot.stats.errorCount > 0]) = 0";
        expectedValue = "true";
        interval = 300;
      }
      {
        name = "Kopia Mum Backup";
        type = "json-query";
        url = "http://localhost:51516/api/v1/sources";
        basicAuthUser = "abl030";
        basicAuthPass = "billand1";
        jsonPath = "$count(sources[lastSnapshot.stats.errorCount > 0]) = 0";
        expectedValue = "true";
        interval = 300;
      }
    ];
    # Only require /mnt/data - mnt-mum is handled via automount dependency above
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [];
  }
