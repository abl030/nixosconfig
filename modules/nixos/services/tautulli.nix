{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.tautulli;
in {
  options.homelab.services.tautulli = {
    enable = lib.mkEnableOption "Tautulli Plex monitoring (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/plexpy";
      description = "Directory where Tautulli stores its data.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tautulli = {
      enable = true;
      port = 8181;
      inherit (cfg) dataDir;
      configFile = "${cfg.dataDir}/config.ini";
    };

    # #257: upstream tautulli ships no sandboxing — it ran with the host's
    # full /mnt/* tree RW-visible. Tautulli writes only to its virtiofs
    # dataDir (config, db, logs, cache, backups), so add ProtectSystem=strict
    # and blank /mnt to just that one bound dir. RequiresMountsFor orders the
    # fail-loud bind after mnt-virtio.mount.
    # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
    systemd.services.tautulli = {
      unitConfig.RequiresMountsFor = [cfg.dataDir];
      serviceConfig = {
        ProtectSystem = "strict";
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "tau.ablz.au";
          port = 8181;
        }
      ];

      monitoring.monitors = [
        {
          name = "Tautulli";
          url = "https://tau.ablz.au/";
        }
      ];

      # See #253 audit. Plex stats viewer with no actionable failure log
      # fingerprint (outages surface via the Kuma HTTP monitor above).
      # NAMESPACE/bind start-failures page ONCE via the fleet-wide "Service
      # failed to start (sandbox/namespace)" alert in alerting.nix — no
      # per-service entry (storm de-collide 2026-06-26).
      monitoring.errorPatterns = []; # ^ namespace → fleet alert; real outages → Kuma
    };
  };
}
