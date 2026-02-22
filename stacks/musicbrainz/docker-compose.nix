{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  stackName = "musicbrainz-stack";
  projectName = "musicbrainz";

  # Base compose from flake input — build contexts resolve relative to this path
  baseCompose = "${inputs.musicbrainz-docker}/docker-compose.yml";

  # lrclib has no public Docker image — build from source (flake input)
  lrclibBuildOverride = pkgs.writeText "musicbrainz-lrclib-build.yml" ''
    services:
      lrclib:
        build: ${inputs.lrclib-src}
  '';

  # Override files from our repo — isolated via builtins.path for stable store paths
  postgresOverride = builtins.path {
    path = ./overrides/postgres-settings.yml;
    name = "musicbrainz-postgres-settings.yml";
  };
  memoryOverride = builtins.path {
    path = ./overrides/memory-settings.yml;
    name = "musicbrainz-memory-settings.yml";
  };
  volumeOverride = builtins.path {
    path = ./overrides/volume-settings.yml;
    name = "musicbrainz-volume-settings.yml";
  };
  lmdOverride = builtins.path {
    path = ./overrides/lmd-settings.yml;
    name = "musicbrainz-lmd-settings.yml";
  };

  encEnv = config.homelab.secrets.sopsFile "musicbrainz.env";

  podman = import ../lib/podman-compose.nix {inherit config lib pkgs;};

  volumeBase = "/mnt/docker/musicbrainz/volumes";

  # Build step — runs before up on every start (fast no-op when layers cached)
  buildStep = [
    "${pkgs.podman}/bin/podman compose --project-name ${projectName} -f ${baseCompose} -f ${postgresOverride} -f ${memoryOverride} -f ${volumeOverride} -f ${lmdOverride} -f ${lrclibBuildOverride} build"
  ];
in {
  systemd.tmpfiles.rules = [
    "d ${volumeBase}/mqdata    0755 abl030 users -"
    "d ${volumeBase}/pgdata    0755 abl030 users -"
    "d ${volumeBase}/solrdata  0755 abl030 users -"
    "d ${volumeBase}/dbdump    0755 abl030 users -"
    "d ${volumeBase}/solrdump  0755 abl030 users -"
    "d ${volumeBase}/lmdconfig 0755 abl030 users -"
    "d ${volumeBase}/lrclib    0755 abl030 users -"
  ];

  imports = [
    (podman.mkService {
      inherit stackName;
      description = "MusicBrainz Mirror + LMD Stack";
      inherit projectName;
      composeFile = baseCompose;
      extraComposeFiles = [postgresOverride memoryOverride volumeOverride lmdOverride lrclibBuildOverride];
      composeArgs = "--project-name ${projectName}";
      envFiles = [
        {
          sopsFile = encEnv;
          runFile = "/run/user/%U/secrets/${stackName}.env";
        }
      ];
      preStart = buildStep;
      firewallPorts = [5000 5001 3300];
      stackMonitors = [
        {
          name = "LMD (Lidarr Metadata)";
          url = "http://192.168.1.29:5001/";
        }
        {
          name = "LRCLIB";
          url = "http://192.168.1.29:3300/";
        }
      ];
      startupTimeoutSeconds = 600;
      after = ["network-online.target"];
      wants = ["network-online.target"];
    })
  ];

  home-manager.users.abl030.systemd.user = {
    services.musicbrainz-reindex = {
      Unit.Description = "MusicBrainz weekly Solr reindex";
      Service = {
        Type = "oneshot";
        Environment = [
          "XDG_RUNTIME_DIR=/run/user/1000"
          "CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock"
        ];
        ExecStart = "${pkgs.podman}/bin/podman exec musicbrainz-indexer-1 python -m sir reindex --entity-type artist --entity-type release";
      };
    };
    timers.musicbrainz-reindex = {
      Unit.Description = "MusicBrainz weekly Solr reindex timer";
      Timer = {
        OnCalendar = "Sun 01:00";
        Persistent = true;
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
