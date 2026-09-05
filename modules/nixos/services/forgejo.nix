{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.forgejo;
  dumpDir = "/mnt/data/Life/Andy/Code/forgejo-dumps";
  mergeSigningPublicKey = ./forgejo-merge-signing-key.pub;
  mergeSigningCredential = "/run/credentials/forgejo.service/repository-signing-key.pub";
  dumpSigningCredential = "/run/credentials/forgejo-dump.service/repository-signing-key.pub";
  dumpCommand = pkgs.writeShellApplication {
    name = "forgejo-dump-with-private-config";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      set -euo pipefail

      config="$RUNTIME_DIRECTORY/app.ini"
      install -m 0600 ${lib.escapeShellArg "${cfg.dataDir}/custom/conf/app.ini"} "$config"
      ${lib.getExe' config.services.forgejo.package "environment-to-ini"} --config "$config"
      chmod 0400 "$config"
      exec ${lib.getExe config.services.forgejo.package} dump \
        --config "$config" \
        --type zip
    '';
  };
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
    assertions = [
      {
        assertion =
          config.systemd.services.forgejo-dump.environment.FORGEJO__REPOSITORY_0x2E_SIGNING__SIGNING_KEY
          == dumpSigningCredential;
        message = "forgejo dump must override the repository signing key with its unit-local credential path";
      }
      {
        assertion =
          lib.elem
          "repository-signing-key.pub:${mergeSigningPublicKey}"
          config.systemd.services.forgejo-dump.serviceConfig.LoadCredential;
        message = "forgejo dump must receive its own repository-signing public-key credential";
      }
      {
        assertion =
          config.systemd.services.forgejo-dump.serviceConfig.ExecStart
          == "${dumpCommand}/bin/forgejo-dump-with-private-config";
        message = "forgejo dump must consume its unit-local signing override through the private-config wrapper";
      }
    ];

    # Private key is encrypted only to doc2 (+ editor/break-glass). systemd copies
    # it into the Forgejo service's private credentials directory; the forgejo
    # account cannot read the source secret outside that service.
    sops.secrets."forgejo/merge-signing-key" = {
      sopsFile = config.homelab.secrets.sopsFile "forgejo-merge-signing-key";
      format = "binary";
      mode = "0400";
    };

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
        "repository.signing" = {
          FORMAT = "ssh";
          SIGNING_KEY = mergeSigningCredential;
          SIGNING_NAME = "Forgejo Merge";
          SIGNING_EMAIL = "forgejo-merge@ablz.au";
          # Forgejo cannot validate the fleet's signing-only SSH keys because
          # those keys are intentionally absent from its login-key database.
          # Use the fixed service committer identity, sign every server-created
          # merge, and let fleet-side policy verify both parents and constrain
          # this key to deterministic merges.
          DEFAULT_TRUST_MODEL = "committer";
          MERGES = "always";
          CRUD_ACTIONS = "never";
          WIKI = "never";
          INITIAL_COMMIT = "never";
        };
        time.DEFAULT_UI_LOCATION = "Australia/Perth";
        security.LOGIN_REMEMBER_DAYS = 31;
        session = {
          COOKIE_SECURE = true;
          # Keep sessions across service restarts; browser persistence remains
          # opt-in through the 31-day "Remember me" cookie.
          PROVIDER = "file";
          PROVIDER_CONFIG = "${cfg.dataDir}/data/sessions";
        };
        log.LEVEL = "Info";
      };
    };

    # Keep the admin CLI at a stable path for token/account operations instead
    # of discovering the package's versioned /nix/store path from ExecStart.
    environment.systemPackages = [config.services.forgejo.package];

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
            LoadCredential = [
              "repository-signing-key:${config.sops.secrets."forgejo/merge-signing-key".path}"
              "repository-signing-key.pub:${mergeSigningPublicKey}"
            ];
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
          # systemd credential directories are private to each unit. The shared
          # app.ini points at forgejo.service's credential directory, which a
          # sibling dump unit cannot traverse. The dump wrapper makes a private
          # runtime copy, applies Forgejo's environment-to-ini helper, and passes
          # that exact config to `forgejo dump`. Merely exporting the variable is
          # insufficient: Forgejo does not consume it without the helper.
          environment.FORGEJO__REPOSITORY_0x2E_SIGNING__SIGNING_KEY = dumpSigningCredential;
          serviceConfig = {
            ExecStart = lib.mkForce "${dumpCommand}/bin/forgejo-dump-with-private-config";
            LoadCredential = [
              "repository-signing-key.pub:${mergeSigningPublicKey}"
            ];
            RuntimeDirectory = "forgejo-dump";
            RuntimeDirectoryMode = "0700";
            NoNewPrivileges = true;
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
      # /api/healthz monitor above). The #257 fail-loud BindPaths for the
      # virtiofs stateDir and NFS dump dir now page ONCE via the fleet-wide
      # "Service failed to start (sandbox/namespace)" alert in alerting.nix —
      # no per-service entries, so one stale mount can't fan out into N
      # identical pages (storm de-collide 2026-06-26).
      monitoring.errorPatterns = []; # ^ namespace → fleet alert; real outages → Kuma
    };
  };
}
