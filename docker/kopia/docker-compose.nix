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
  inherit (config.homelab.containers) dataRoot;
in
  podman.mkService {
    inherit stackName;
    description = "Kopia Podman Compose Stack";
    projectName = "kopia";
    inherit composeFile;
    inherit envFiles;
    preStart = [
      "/run/current-system/sw/bin/mkdir -p ${dataRoot}/kopiaphotos/config ${dataRoot}/kopiaphotos/cache ${dataRoot}/kopiaphotos/logs ${dataRoot}/kopiaphotos/tmp ${dataRoot}/kopiamum/config ${dataRoot}/kopiamum/cache ${dataRoot}/kopiamum/logs ${dataRoot}/kopiamum/tmp"
      # Use root chown for existing data (podman unshare fails on data owned by different UIDs)
      "/run/current-system/sw/bin/chown -R 1000:1000 ${dataRoot}/kopiaphotos ${dataRoot}/kopiamum"
    ];
    # Only require /mnt/data - mnt-mum is handled via automount dependency above
    requiresMounts = ["/mnt/data"];
    wants = dependsOn;
    after = dependsOn;
    firewallPorts = [51515 51516];
  }
