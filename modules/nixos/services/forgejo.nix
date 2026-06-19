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
          # warned about: use the built-in Go SSH server on :2222 (sshd already
          # owns 22 on doc2). Operational notes and the cutover key cleanup gate
          # live in docs/wiki/services/forgejo.md.
          DISABLE_SSH = false;
          START_SSH_SERVER = true;
          SSH_PORT = 2222;
          # BIND-ALL-INTERFACES-OK: Forgejo is the fleet git write root — every
          # host pushes here over SSH (2222 is opened in the firewall on
          # purpose). Auth is SSH-key based, so all-interfaces is intentional.
          SSH_LISTEN_HOST = "0.0.0.0";
          SSH_LISTEN_PORT = 2222;
          SSH_DOMAIN = "git.ablz.au";
          OFFLINE_MODE = true;
        };
        service = {
          DISABLE_REGISTRATION = true;
          # Anonymous read for PUBLIC repos only (the nixosconfig flake becomes
          # the public Forgejo write root, #235). Other repos (agents, books)
          # stay private — DEFAULT_PRIVATE below keeps new repos private, so
          # this flip exposes nothing until a repo is explicitly made public.
          REQUIRE_SIGNIN_VIEW = false;
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

    systemd = {
      # virtiofs path needs explicit creation; upstream module's StateDirectory
      # only manages /var/lib paths cleanly. Create dump dir on NFS too —
      # /mnt/data is mode 1777 so this works without an export-side fix.
      tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 forgejo forgejo - -"
        "d ${dumpDir} 0750 forgejo forgejo - -"
      ];

      services = {
        # Sandbox /mnt for both forgejo units (#257). Upstream forgejo.service is
        # hardened but reaches its NFS dump dir via ReadWritePaths, which
        # silently skips a missing/contested source (the paperless EROFS class).
        # forgejo-dump.service is wholly unhardened (ProtectSystem=no) and sees
        # every /mnt/* export RW. Replace both with a blank /mnt + fail-loud
        # BindPaths binding only the two paths forgejo needs: its virtiofs
        # stateDir (repos, app.ini, .secrets/) and its NFS dump dir.
        # RequiresMountsFor orders each unit after the backing mounts so the
        # fail-loud binds can't race them at boot.
        # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
        forgejo = {
          unitConfig.RequiresMountsFor = [cfg.dataDir dumpDir];
          serviceConfig = {
            TemporaryFileSystem = "/mnt";
            BindPaths = [cfg.dataDir dumpDir];
            # Drop upstream's ReadWritePaths (custom, repositories, data/lfs,
            # dump dir — all under our two BindPaths, already rw). Under the
            # blank /mnt tmpfs those become self-binds, and the `data/lfs` entry
            # (LFS is disabled, dir absent) can't be skip-if-missing the way it
            # is in the host namespace → 226/NAMESPACE. BindPaths makes the whole
            # stateDir + dump dir rw, so this list is pure redundancy now.
            ReadWritePaths = lib.mkForce [];
          };
        };

        # Dump only fires when NFS is up — stale handle would crash it otherwise.
        forgejo-dump = {
          after = ["mnt-data.mount"];
          requires = ["mnt-data.mount"];
          unitConfig.RequiresMountsFor = [cfg.dataDir dumpDir];
          serviceConfig = {
            TemporaryFileSystem = "/mnt";
            BindPaths = [cfg.dataDir dumpDir];
          };
        };
      };
    };

    # Forgejo's built-in Go SSH server on :2222 (separate from sshd on :22).
    networking.firewall.allowedTCPPorts = [2222];

    homelab = {
      localProxy.hosts = [
        {
          host = "git.ablz.au";
          port = 3023;
          websocket = true;
          # git-over-HTTP push packs (full-history seed, large rebases) exceed
          # nginx's 1m default → HTTP 413. The dev/bot HTTPS push path (signed
          # fleet deploys, #235) needs generous bodies. Unlimited at the proxy;
          # Forgejo enforces its own limits.
          maxBodySize = "0";
        }
      ];

      monitoring.monitors = [
        {
          name = "Forgejo";
          url = "https://git.ablz.au/api/healthz";
        }
      ];

      # See #253 audit. The git server itself has no actionable failure
      # fingerprint in casual operation (outages surface via the Kuma
      # /api/healthz monitor above), but #257 added fail-loud BindPaths for
      # the virtiofs stateDir and NFS dump dir — page if either bind fails.
      monitoring.errorPatterns = [
        {
          name = "Forgejo NFS/namespace failure";
          unit = "forgejo.service";
          pattern = "(?i)Failed at step NAMESPACE";
          severity = "critical";
          summary = "forgejo cannot bind its state/dump dirs — git server is down";
          description = "A BindPaths source (/mnt/virtio/forgejo or the NFS dump dir) is missing or stale — check mnt-virtio.mount / mnt-data.mount on doc2.";
          threshold = 0;
        }
        {
          name = "Forgejo dump namespace failure";
          unit = "forgejo-dump.service";
          pattern = "(?i)Failed at step NAMESPACE";
          severity = "warning";
          summary = "forgejo nightly dump cannot bind its dirs — backups are not running";
          threshold = 0;
        }
      ];
    };
  };
}
