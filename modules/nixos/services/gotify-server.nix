{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.gotify;
in {
  options.homelab.services.gotify = {
    enable = lib.mkEnableOption "Gotify push notification server (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gotify-server";
      description = "Directory where Gotify stores its data (database, uploads, plugins).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.gotify = {
      enable = true;
      environment = {
        GOTIFY_SERVER_PORT = 8050;
      };
    };

    # Static user so we can own virtiofs data without DynamicUser conflicts
    users.users.gotify = {
      isSystemUser = true;
      group = "gotify";
      home = cfg.dataDir;
    };
    users.groups.gotify = {};

    # Override upstream service to use static user and custom data dir.
    # #257: upstream gotify ships no sandboxing — full /mnt/* RW-visible.
    # Gotify writes only its dataDir (db, uploads, plugins), so add
    # ProtectSystem=strict + blank /mnt bound to that one virtiofs dir.
    # RequiresMountsFor orders the fail-loud bind after mnt-virtio.mount.
    systemd.services.gotify-server = {
      unitConfig.RequiresMountsFor = [cfg.dataDir];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "gotify";
        Group = "gotify";
        WorkingDirectory = lib.mkForce cfg.dataDir;
        StateDirectory = lib.mkForce "";
        ProtectSystem = "strict";
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
      };
    };

    networking.firewall.allowedTCPPorts = [8050];

    homelab = {
      localProxy.hosts = [
        {
          host = "gotify.ablz.au";
          port = 8050;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Gotify";
          url = "https://gotify.ablz.au/";
        }
      ];

      # See #253 audit + rules-doc "Per-service errorPatterns".
      # If Gotify fails, no alerts reach the phone. Critical.
      monitoring.errorPatterns = [
        {
          name = "Gotify server failure";
          unit = "gotify-server.service";
          pattern = "(?i)panic|fatal|listen tcp.*bind|Failed at step NAMESPACE";
          severity = "critical";
          summary = "Gotify server crashed — push notifications offline";
          # Single-shot: panic/fatal lines emit once before the process
          # exits. Sustained-threshold would silently lose the alert.
          threshold = 0;
        }
      ];
    };
  };
}
