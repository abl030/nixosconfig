{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.bdday;
  defaultPackage = inputs.bdday.packages.${pkgs.system}.default;
in {
  options.homelab.services.bdday = {
    enable = lib.mkEnableOption "Cullen biodynamic day API and dashboard";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "bdday package from the locked Forgejo flake input.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "bd.ablz.au";
      description = "LAN HTTPS hostname served by homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8849;
      description = "Loopback HTTP port for the bdday service.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.bdday = {
      description = "Cullen biodynamic day API and dashboard";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/bdday serve --listen 127.0.0.1:${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = "5s";

        # Stateless service: an ephemeral identity and no writable application
        # paths. The package and embedded dashboard are read directly from the
        # immutable Nix store.
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

        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = ["@system-service" "~@privileged"];
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];

        # nginx reaches the service over host loopback. The same policy denies
        # every non-loopback destination, so request handling has no runtime
        # egress path or external dependency.
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        UMask = "0077";
      };
    };

    # Ordinary LAN localProxy entry: this inherits unproxied Cloudflare DNS to
    # doc1's RFC1918 address, nginx TLS/ACME, and a loopback HTTP upstream.
    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "Biodynamic day dashboard";
          url = "https://${cfg.fqdn}/healthz";
        }
      ];

      # Stateless and deterministic: /healthz exercises the server/router and
      # there is no database or write path that needs a separate deep probe.
      deepProbes = [];

      errorPatterns = [
        {
          name = "bdday Rust process panic";
          unit = "bdday.service";
          pattern = "panicked at|fatal runtime error";
          severity = "critical";
          summary = "bdday crashed because of a Rust panic";
          description = ''
            Rust emits these stable terminal fingerprints for an unhandled
            panic or runtime abort. The process exits after one occurrence, so
            waiting for the default repeated-match threshold would miss it;
            inspect the bdday journal and the request immediately preceding it.
          '';
          threshold = 0;
        }
      ];
    };
  };
}
