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
      description = "Public/LAN FQDN for the controller UI (surfaced via homelab.localProxy).";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/unifi";
      description = ''
        Persistent controller state (MongoDB, keystore, autobackups). The
        upstream services.unifi module hard-codes /var/lib/unifi via
        StateDirectory, so this dir is bind-mounted over it. Keep it on
        portable, kopia-backed storage (virtiofs) — never the disposable VM
        root, which is neither portable nor in the backup scope.
      '';
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
      # openFirewall opens the device-facing ports (inform 8080, STUN 3478,
      # discovery, etc.) that APs/switches need for adoption + check-in. It does
      # NOT open the 8443 UI — that stays on loopback behind homelab.localProxy.
      openFirewall = true;
      inherit (cfg) mongodbPackage maximumJavaHeapSize;
      extraJvmOptions = ["-XX:+UseParallelGC"];
    };

    # Relocate controller state off the disposable VM root onto portable,
    # kopia-backed virtiofs storage. services.unifi hard-codes /var/lib/unifi
    # (StateDirectory + WorkingDirectory + mongod --dbpath), so bind-mount the
    # real dataDir over it rather than fight the upstream module.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 unifi unifi -"
    ];
    fileSystems."/var/lib/unifi" = {
      device = cfg.dataDir;
      fsType = "none";
      options = [
        "bind"
        "nofail"
        "x-systemd.requires-mounts-for=/mnt/virtio"
      ];
    };

    # UI (8443, self-signed HTTPS) surfaced via the nginx localProxy like every
    # other web service. recommendedProxySettings sends `Host: $host`, so
    # UniFi's CSRF/Origin check sees a matching Host and login works — the whole
    # reason the hand-rolled Caddy reverse_proxy 403'd. https+insecureSkipVerify
    # handle the controller's self-signed cert; websocket carries /wss.
    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        port = 8443;
        https = true;
        insecureSkipVerify = true;
        websocket = true;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "UniFi Controller";
          url = "https://${cfg.fqdn}/";
        }
      ];
      # Stateful, but UniFi's write path (MongoDB) is embedded and its strongest
      # practical health signal is device check-in + the UI/API monitor above.
      # A SQL/deep probe would mean reaching into the bundled mongod on 27117;
      # the shallow UI monitor plus the fatal-error patterns below cover the
      # realistic failure classes (process death, OOM, Mongo start failure).
      deepProbes = [];
      # NOTE: UniFi logs app-level detail to /var/lib/unifi/logs/server.log (a
      # file), not the journal — so these journal patterns only catch what hits
      # stderr: JVM/process fatals. That's the critical class (process down);
      # richer app-log alerting would need server.log shipped to Loki (follow-up).
      errorPatterns = [
        {
          name = "UniFi controller fatal error";
          unit = "unifi.service";
          pattern = "(?i)(OutOfMemoryError|CrashOnOutOfMemoryError|failed to start)";
          severity = "critical";
          summary = "UniFi controller hit a JVM/process fatal (OOM or start failure)";
        }
      ];
    };
  };
}
