{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.forgejo;
  dumpDir = "/mnt/data/Life/Andy/Code/forgejo-dumps";
in {
  options.homelab.services.forgejo = {
    enable = lib.mkEnableOption "Forgejo self-hosted git forge";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/forgejo";
      description = "Forgejo state directory (repos, attachments, .secrets/, app.ini).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.forgejo = {
      enable = true;
      package = pkgs.forgejo-lts;
      stateDir = cfg.dataDir;
      lfs.enable = false;
      database.type = "sqlite3";

      dump = {
        enable = true;
        interval = "daily";
        backupDir = dumpDir;
      };

      settings = {
        server = {
          DOMAIN = "git.ablz.au";
          ROOT_URL = "https://git.ablz.au/";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = 3023;
          # SSH re-enabled 2026-04-30 after v0 hit the friction the brainstorm
          # warned about — using the built-in Go SSH server on :2222 (sshd
          # already owns 22 on doc2). Existing master-fleet-identity key is
          # uploaded to the user's Forgejo profile post-deploy.
          DISABLE_SSH = false;
          START_SSH_SERVER = true;
          SSH_PORT = 2222;
          SSH_LISTEN_HOST = "0.0.0.0";
          SSH_LISTEN_PORT = 2222;
          SSH_DOMAIN = "git.ablz.au";
          OFFLINE_MODE = true;
        };
        service = {
          DISABLE_REGISTRATION = true;
          REQUIRE_SIGNIN_VIEW = true;
          DEFAULT_KEEP_EMAIL_PRIVATE = true;
        };
        repository = {
          DEFAULT_PRIVATE = "private";
          DEFAULT_PUSH_CREATE_PRIVATE = true;
        };
        time.DEFAULT_UI_LOCATION = "Australia/Perth";
        session.COOKIE_SECURE = true;
        log.LEVEL = "Info";
      };
    };

    # virtiofs path needs explicit creation; upstream module's StateDirectory
    # only manages /var/lib paths cleanly. Create dump dir on NFS too —
    # /mnt/data is mode 1777 so this works without an export-side fix.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 forgejo forgejo - -"
      "d ${dumpDir} 0750 forgejo forgejo - -"
    ];

    # Dump only fires when NFS is up — stale handle would crash it otherwise.
    systemd.services.forgejo-dump = {
      after = ["mnt-data.mount"];
      requires = ["mnt-data.mount"];
    };

    # Forgejo's built-in Go SSH server on :2222 (separate from sshd on :22).
    networking.firewall.allowedTCPPorts = [2222];

    homelab = {
      localProxy.hosts = [
        {
          host = "git.ablz.au";
          port = 3023;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Forgejo";
          url = "https://git.ablz.au/api/healthz";
        }
      ];
    };
  };
}
