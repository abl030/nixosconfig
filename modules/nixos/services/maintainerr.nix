{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.maintainerr;
  image = "ghcr.io/maintainerr/maintainerr:latest";
  maintainerrUid = 2025;
  maintainerrGid = 2025;
in {
  options.homelab.services.maintainerr = {
    enable = lib.mkEnableOption "Maintainerr media-library maintenance UI";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/maintainerr";
      description = "Directory for Maintainerr's SQLite database and configuration.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "maintain.ablz.au";
      description = "LAN-facing hostname served by the local reverse proxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6246;
      description = "Loopback port for the Maintainerr web UI.";
    };
  };

  config = lib.mkIf cfg.enable {
    users = {
      groups.maintainerr.gid = maintainerrGid;
      users.maintainerr = {
        isSystemUser = true;
        uid = maintainerrUid;
        group = "maintainerr";
      };
    };

    systemd = {
      tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 maintainerr maintainerr - -"
      ];

      services.podman-maintainerr = {
        unitConfig.RequiresMountsFor = [cfg.dataDir];
        serviceConfig = {
          # doc2 services see no other /mnt content. The app receives only its
          # state directory and deliberately has no media-library mount until
          # leftover-folder deletion is explicitly designed and approved.
          TemporaryFileSystem = "/mnt";
          BindPaths = [cfg.dataDir];
        };
      };
    };

    virtualisation.oci-containers.containers.maintainerr = {
      inherit image;
      autoStart = true;
      pull = "newer";
      ports = ["127.0.0.1:${toString cfg.port}:6246"];
      environment = {
        TZ = "Australia/Perth";
        TELEMETRY = "off";
      };
      volumes = [
        "${cfg.dataDir}:/opt/data:rw"
      ];
      # Upstream supports an arbitrary runtime user. It listens on an
      # unprivileged port and therefore needs no Linux capabilities.
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--user=${toString maintainerrUid}:${toString maintainerrGid}"
          "--memory=1g"
          "--pids-limit=256"
        ];
    };

    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-maintainerr.service";
          inherit image;
        }
      ];

      localProxy.hosts = [
        {
          host = cfg.fqdn;
          inherit (cfg) port;
          websocket = true;
        }
      ];

      monitoring = {
        monitors = [
          {
            name = "Maintainerr";
            url = "https://${cfg.fqdn}/api/health/ready";
          }
        ];

        deepProbes = [
          {
            name = "Maintainerr state write-path";
            command = "${pkgs.callPackage ./probes/check-maintainerr.nix {}}/bin/check-maintainerr ${toString cfg.port}";
            interval = "5m";
            intervalSecs = 450;
            requiresUnit = ["podman-maintainerr.service"];
          }
        ];

        # The deep probe covers HTTP readiness, SQLite reachability and actual
        # writes through the state bind mount. No additional stable log
        # fingerprint is needed; failures surface through its missed heartbeat.
        errorPatterns = [];
      };
    };
  };
}
