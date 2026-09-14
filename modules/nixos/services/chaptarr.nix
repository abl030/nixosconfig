# Parallel book-library trial. See docs/wiki/services/book-platform-exploration.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.chaptarr;
  image = "docker.io/chaptarr/chaptarr:latest";
  lan = config.homelab.localProxy.localIp;
  existingAudio = "/mnt/data/Media/Books/Audiobooks";
  existingEbooks = "/mnt/data/Media/Books/Calibre LIbrary";
in {
  options.homelab.services.chaptarr = {
    enable = lib.mkEnableOption "Chaptarr collection-management trial";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/chaptarr";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8789;
    };
  };
  config = lib.mkIf cfg.enable {
    users.groups.chaptarr.gid = 2021;
    users.users.chaptarr = {
      isSystemUser = true;
      uid = 2021;
      group = "chaptarr";
      extraGroups = ["users"];
    };
    systemd.tmpfiles.rules = map (p: "d ${cfg.dataDir}/${p} 0750 chaptarr chaptarr - -") ["" "config" "audiobooks" "ebooks" "downloads"];
    networking.firewall.allowedTCPPorts = [cfg.port];
    virtualisation.oci-containers.containers.chaptarr = {
      inherit image;
      ports = ["${lan}:${toString cfg.port}:8789" "127.0.0.1:${toString cfg.port}:8789"];
      environment = {
        PUID = "2021";
        PGID = "2021";
        TZ = "Australia/Perth";
      };
      volumes = [
        "${cfg.dataDir}/config:/config"
        "${cfg.dataDir}/audiobooks:/audiobooks"
        "${cfg.dataDir}/ebooks:/ebooks"
        "${cfg.dataDir}/downloads:/downloads"
        "${existingAudio}:/existing/audiobooks:ro"
        "/mnt/chaptarr-existing-ebooks:/existing/ebooks:ro"
      ];
      # Entrypoint skips user remapping when already unprivileged.
      extraOptions = config.homelab.podman.hardenOptions ++ ["--user=2021:2021" "--group-add=100" "--memory=2g" "--pids-limit=256"];
    };
    systemd.services.podman-chaptarr = {
      unitConfig.RequiresMountsFor = [cfg.dataDir existingAudio "\"${existingEbooks}\""];
      serviceConfig = {
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
        BindReadOnlyPaths = [existingAudio "\"${existingEbooks}:/mnt/chaptarr-existing-ebooks\""];
      };
    };
    homelab.podman.containers = [
      {
        unit = "podman-chaptarr.service";
        inherit image;
      }
    ];
    homelab.nfsWatchdog.podman-chaptarr.path = existingAudio;
    homelab.monitoring = {
      monitors = [
        {
          name = "Chaptarr trial";
          url = "http://doc2:${toString cfg.port}/ping";
        }
      ];
      deepProbes = [
        {
          name = "Chaptarr trial state";
          command = "${pkgs.callPackage ./probes/check-book-trial.nix {}}/bin/check-book-trial chaptarr ${cfg.dataDir} ${toString cfg.port}";
          interval = "5m";
          intervalSecs = 300;
        }
      ];
      errorPatterns = [
        {
          name = "Chaptarr database failure";
          unit = "podman-chaptarr.service";
          pattern = "database disk image is malformed|database or disk is full";
          severity = "critical";
          summary = "Chaptarr trial cannot persist its catalog";
          threshold = 0;
        }
      ];
    };
  };
}
