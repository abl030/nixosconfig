{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.mrnews;
  defaultPackage = inputs.mrnews.packages.${pkgs.system}.default;
in {
  options.homelab.services.mrnews = {
    enable = lib.mkEnableOption "Margaret River News static Hugo site";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Built mrnews site from the locked Forgejo flake input.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "mrnews.ablz.au";
      description = "LAN/tailnet HTTPS hostname served by homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8850;
      description = "Loopback port for the sandboxed static file server.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.mrnews = {
      description = "Margaret River News static site";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.static-web-server}/bin/static-web-server"
          "--host 127.0.0.1"
          "--port ${toString cfg.port}"
          "--root ${cfg.package}"
          # The site is replaced atomically at the same URLs. The server's
          # default one-day cache otherwise leaves open browser tabs on the old
          # home page after a news deployment.
          "--cache-control-headers false"
          "--log-level warn"
        ];

        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallFilter = ["@system-service" "~@privileged"];
        SystemCallArchitectures = "native";
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        UMask = "0077";
      };
    };

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "Margaret River News";
          url = "https://${cfg.fqdn}/";
        }
      ];
      deepProbes = [];
      errorPatterns = [];
    };
  };
}
