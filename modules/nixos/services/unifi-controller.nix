{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.unifiController;
in {
  options.homelab.services.unifiController = {
    enable = lib.mkEnableOption "UniFi Network controller";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "unifi.ablz.au";
      description = "Public/LAN FQDN for the UniFi controller UI.";
    };

    maximumJavaHeapSize = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = "Maximum UniFi JVM heap in MiB.";
    };

    mongodbPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mongodb-7_0;
      defaultText = lib.literalExpression "pkgs.mongodb-7_0";
      description = "MongoDB package used by the upstream UniFi module.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.unifi = {
      enable = true;
      openFirewall = true;
      inherit (cfg) mongodbPackage maximumJavaHeapSize;
      extraJvmOptions = ["-XX:+UseParallelGC"];
    };

    # Upstream openFirewall omits 8443 (UI), intentionally keeping it behind
    # Caddy for humans. Keep device-facing ports open via services.unifi.
    services.caddy.virtualHosts.${cfg.fqdn} = {
      useACMEHost = "ablz.au";
      extraConfig = ''
        reverse_proxy https://127.0.0.1:8443 {
          transport http {
            tls_insecure_skip_verify
          }
        }
      '';
    };

    homelab.monitoring = {
      monitors = [
        {
          name = "UniFi Controller";
          url = "https://${cfg.fqdn}/";
        }
      ];
      # UniFi is stateful, but the strongest practical migration signal is device
      # check-in plus the UI/API monitor; MongoDB is embedded and managed by the
      # upstream module in /var/lib/unifi.
      deepProbes = [];
      errorPatterns = [
        {
          name = "UniFi controller fatal error";
          unit = "unifi.service";
          pattern = "(?i)(OutOfMemoryError|CrashOnOutOfMemoryError|Exception|failed to start|database.*(corrupt|error)|Mongo.*(error|failed))";
          severity = "critical";
          summary = "UniFi controller is logging fatal/runtime errors";
        }
      ];
    };
  };
}
