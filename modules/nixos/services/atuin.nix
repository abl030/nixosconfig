{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.atuin;
  # See #232 — passwordFile points at a sops-managed dotenv with POSTGRES_PASSWORD.
  # Path is deterministic from the sops.secrets entry name; declared in `config`
  # below.
  pgpassFile = "/run/secrets/atuin-pgpass";
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "atuin";
    hostNum = 1;
    inherit (cfg) dataDir;
    passwordFile = pgpassFile;
  };
in {
  options.homelab.services.atuin = {
    enable = lib.mkEnableOption "Atuin shell history sync server";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/atuin-server";
      description = "Directory for Atuin server state (contains postgres subdirectory)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Self-contained PG instance in a NixOS container
    containers.atuin-db = pgc.containerConfig;

    sops.secrets."atuin-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "atuin-pgpass.env";
      format = "dotenv";
      mode = "0400";
    };

    services.atuin = {
      enable = true;
      port = 8888;
      host = "0.0.0.0";
      openRegistration = true;
      database = {
        createLocally = false;
        # No-password URI here is cosmetic — the runtime ATUIN_DB_URI is
        # constructed in atuin-db-uri.service below from POSTGRES_PASSWORD,
        # then injected via systemd EnvironmentFile, which atuin reads.
        uri = pgc.dbUri;
      };
    };

    # ExecStartPre that builds /run/atuin-db-uri/db-env from POSTGRES_PASSWORD.
    # Keeps the password out of /nix/store and out of static unit env, while
    # still letting atuin connect via its standard ATUIN_DB_URI mechanism.
    #
    # The env file lives in this unit's OWN RuntimeDirectory, not atuin's
    # (upstream nixpkgs sets RuntimeDirectory=atuin on atuin.service, which
    # systemd wipes whenever atuin.service stops; the RemainAfterExit oneshot
    # then doesn't re-run on restart, leaving the EnvironmentFile missing
    # and atuin failing with `Result: resources`). Failure observed
    # 2026-05-11 during a tailscale-driven rebuild restart on doc2.
    #
    # restartTriggers includes the sops secret path so out-of-band password
    # rotations (sops edit + systemctl restart, no nixos-rebuild) re-render
    # the db-env file. Without this, RemainAfterExit would skip the rebuild
    # and atuin would reconnect with the stale URI.
    systemd.services.atuin-db-uri = {
      description = "Render atuin DB URI with PG password";
      wantedBy = ["multi-user.target"];
      before = ["atuin.service"];
      restartTriggers = [config.sops.secrets."atuin-pgpass".path];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "atuin-db-uri";
        RuntimeDirectoryMode = "0700";
        EnvironmentFile = config.sops.secrets."atuin-pgpass".path;
        ExecStart = pkgs.writeShellScript "atuin-db-uri" ''
          set -eu
          umask 0177
          {
            printf 'ATUIN_DB_URI=postgresql://atuin:%s@%s:%d/atuin\n' \
              "$POSTGRES_PASSWORD" "${pgc.dbHost}" ${toString pgc.dbPort}
          } > /run/atuin-db-uri/db-env
        '';
      };
    };

    # Atuin must wait for its database container AND the URI builder.
    # restartTriggers: see immich.nix comment — Requires= cascade-stops atuin
    # when the container restarts, but switch-to-configuration won't bring it
    # back unless its own unit file changed. Including atuin-db-uri.service's
    # unit derivation ensures atuin restarts whenever the uri builder is
    # rebuilt, so the env-file path stays in sync.
    systemd.services.atuin = {
      after = ["container@atuin-db.service" "atuin-db-uri.service"];
      requires = ["container@atuin-db.service" "atuin-db-uri.service"];
      restartTriggers = [
        config.systemd.units."container@atuin-db.service".unit
        config.systemd.units."atuin-db-uri.service".unit
        config.sops.secrets."atuin-pgpass".path
      ];
      serviceConfig.EnvironmentFile = ["/run/atuin-db-uri/db-env"];
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "atuin.ablz.au";
          port = 8888;
        }
      ];

      monitoring.monitors = [
        {
          name = "Atuin";
          url = "https://atuin.ablz.au/";
        }
      ];
    };
  };
}
