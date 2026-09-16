# Readaloud trial on independent book copies. See docs/wiki/services/storyteller.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.storyteller;
  image = "registry.gitlab.com/storyteller-platform/storyteller:latest";
  settings = pkgs.writeText "storyteller.json" (builtins.toJSON {
    libraryName = "Andy’s Readalouds";
    webUrl = "https://${cfg.fqdn}";
    transcriptionEngine = "whisper.cpp";
    whisperModel = "base.en";
    whisperThreads = 4;
    parallelTranscodes = 1;
    parallelTranscribes = 1;
    maxTrackLength = 0.5; # Hours; bound transcription memory for long recordings.
  });
  probe = pkgs.writeShellApplication {
    name = "check-storyteller";
    runtimeInputs = [pkgs.python3 pkgs.podman];
    text = ''
      exec python3 ${./probes/storyteller.py} ${lib.escapeShellArg cfg.dataDir} ${toString cfg.port}
    '';
  };
in {
  options.homelab.services.storyteller = {
    enable = lib.mkEnableOption "Storyteller synchronized ebook and audiobook library";
    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "storyteller.ablz.au";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/storyteller";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8001;
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.storyteller.gid = 2026;
    users.users.storyteller = {
      isSystemUser = true;
      uid = 2026;
      group = "storyteller";
    };
    sops.secrets.storyteller-env = {
      sopsFile = config.homelab.secrets.sopsFile "storyteller.env";
      format = "dotenv";
      mode = "0400";
    };
    sops.secrets."storyteller/bootstrap" = {
      sopsFile = config.homelab.secrets.sopsFile "storyteller-bootstrap.json";
      format = "json";
      key = "";
      mode = "0400";
    };
    systemd.tmpfiles.rules = ["d ${cfg.dataDir} 0750 storyteller storyteller - -"];
    virtualisation.oci-containers.containers.storyteller = {
      inherit image;
      ports = ["127.0.0.1:${toString cfg.port}:8001"];
      environmentFiles = [config.sops.secrets.storyteller-env.path];
      environment = {
        PUID = "2026";
        PGID = "2026";
        TZ = "Australia/Perth";
        AUTH_URL = "https://${cfg.fqdn}";
        STORYTELLER_CONFIG = "/etc/storyteller.json";
      };
      volumes = [
        "${cfg.dataDir}:/data"
        "${settings}:/etc/storyteller.json:ro"
      ];
      # Upstream remaps its user and writable image caches before exec'ing gosu.
      # Only private state is mounted; all application processes drop to UID 2026.
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--cap-add=CHOWN"
          "--cap-add=SETUID"
          "--cap-add=SETGID"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=FOWNER"
          "--memory=8g"
          "--memory-swap=10g"
          "--cpus=4"
          "--pids-limit=512"
        ];
    };
    systemd.services.podman-storyteller = {
      restartTriggers = [config.sops.secrets.storyteller-env.path];
      unitConfig.RequiresMountsFor = [cfg.dataDir];
      serviceConfig = {
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
      };
    };
    homelab.podman.containers = [
      {
        unit = "podman-storyteller.service";
        inherit image;
      }
    ];
    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
        websocket = true;
        maxBodySize = "0";
      }
    ];
    homelab.monitoring = {
      monitors = [
        {
          name = "Storyteller";
          url = "https://${cfg.fqdn}/api/health";
        }
      ];
      deepProbes = [
        {
          name = "Storyteller state";
          command = "${probe}/bin/check-storyteller";
          interval = "5m";
          intervalSecs = 300;
          requiresUnit = ["podman-storyteller.service"];
        }
      ];
      errorPatterns = [
        {
          name = "Storyteller database failure";
          unit = "podman-storyteller.service";
          pattern = "SQLITE_CORRUPT|SQLITE_FULL|SQLITE_READONLY|database disk image is malformed";
          severity = "critical";
          summary = "Storyteller cannot read or write its library database";
          threshold = 0;
        }
      ];
    };
  };
}
