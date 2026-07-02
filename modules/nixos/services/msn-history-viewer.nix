# Static MSN history viewer (on doc2). Migrated off the caddy LXC alongside unifi;
# see docs/wiki/services/unifi-controller.md for the edge-split context.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.msnHistoryViewer;

  source = pkgs.fetchFromGitHub {
    owner = "bozdoz";
    repo = "msn-history-viewer";
    rev = "24a1344ae3b15828c32a80a960aeeeb00392bd38";
    hash = "sha256-DldCAw7Fy0rvvmhiKD2LGMebDY+/rhjhCvcwtqWX50M=";
  };

  defaultPackage = pkgs.stdenv.mkDerivation {
    pname = "msn-history-viewer";
    version = "2021-01-17";
    src = source;

    offlineCache = pkgs.fetchYarnDeps {
      src = source;
      hash = "sha256-dto9R8qKy+0dBMowAR/ASDHl+QGNTWlo1mKgpe0K2ZM=";
    };

    nativeBuildInputs = [
      pkgs.yarnConfigHook
      pkgs.yarnBuildHook
      pkgs.nodejs
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r index.html build $out/
      runHook postInstall
    '';
  };
in {
  options.homelab.services.msnHistoryViewer = {
    enable = lib.mkEnableOption "static MSN Messenger history viewer";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "msn.ablz.au";
      description = "FQDN for the viewer (surfaced via homelab.localProxy).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8791;
      description = "Loopback port the sandboxed static server listens on; proxied by homelab.localProxy.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Built static MSN history viewer bundle (served read-only).";
    };
  };

  config = lib.mkIf cfg.enable {
    # This is an UNMAINTAINED third-party bundle. Crucially, the XML parsing runs
    # entirely CLIENT-SIDE in the visitor's browser — the server only hands out
    # read-only static files, so there is no server-side interpreter or upload
    # endpoint. We still serve it from the most locked-down thing we can: a
    # minimal static server, DynamicUser, no state, no writable paths, no
    # capabilities, and no network reach beyond loopback. nginx localProxy fronts
    # it for TLS/DNS like every other web service.
    systemd.services.msn-history-viewer = {
      description = "MSN history viewer (sandboxed static file server)";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.static-web-server}/bin/static-web-server"
          "--host 127.0.0.1"
          "--port ${toString cfg.port}"
          "--root ${cfg.package}"
          "--log-level warn"
        ];

        DynamicUser = true;
        NoNewPrivileges = true; # static server, never needs to gain privilege

        # Read-only world: the served root is a /nix/store path (already ro),
        # and the unit owns no writable state.
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

        # Only the loopback nginx ever connects; no outbound reach at all.
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
          name = "MSN history viewer";
          url = "https://${cfg.fqdn}/";
        }
      ];
      # Static, stateless: no write path or app-log stream; HTTP monitor covers it.
      deepProbes = [];
      errorPatterns = [];
    };
  };
}
