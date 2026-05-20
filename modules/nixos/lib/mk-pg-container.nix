# mk-pg-container.nix — Creates an isolated PostgreSQL instance in a NixOS container.
#
# Returns an attrset with:
#   containerConfig — value for containers.<name>
#   dbUri           — connection string without password (consumer adds password
#                     via PGPASSWORD env or DSN templating in ExecStart wrapper)
#   dbHost          — container-side IP (for TCP connections)
#   dbPort          — 5432
#   hostAddress     — host-side veth IP
#   localAddress    — container-side veth IP
#
# IP addressing: hostNum N → host 192.168.100.(N*2), container 192.168.100.(N*2+1)
# Each service gets a unique hostNum to avoid collisions.
#
# AUTH MODEL (since 2026-05-10):
# Authentication is `scram-sha-256` over TCP from the host-side veth — `trust`
# was abandoned after empirical verification that any OCI container on podman0
# could connect as `postgres` superuser to every nspawn DB in the fleet (the
# Linux IP-forwarding path rewrites source to hostAddress, matching the trust
# rule). See #232 for the audit and the security ramifications walkthrough.
#
# `passwordFile` is REQUIRED — point it at a sops-managed dotenv file
# containing `POSTGRES_PASSWORD=<value>`. The host-side secret can stay
# root-only; the container copies it to a private postgres-readable runtime
# file before setup instead of requiring the bindmount itself to be world-readable.
#
# Recovery / out-of-band ops: peer auth on the local socket inside the
# container is unchanged. `sudo machinectl shell <name>-db` then
# `sudo -u postgres psql` gives a passwordless superuser shell — this is
# the always-available backdoor for schema work or password resets.
#
# CASCADE-STOP GOTCHA (see PR about 2026-04-13 mealie/atuin/discogs-api outage):
# Any long-running service, or oneshot whose active/completed state matters to
# dependents, that `Requires=container@<name>-db.service` MUST declare
#   restartTriggers = [config.systemd.units."container@<name>-db.service".unit];
# Timer-driven oneshots that are expected to be inactive between runs usually do
# not need this.
# NOT `config.containers.<name>-db.config.system.build.toplevel`.
# The former pins the host-side unit wrapper (ExecStart/ExecReload scripts, which
# nixpkgs rebuilds whenever systemd-nspawn helpers change). The latter pins the
# INNER NixOS system of the container, which can stay stable while the wrapper
# changes — causing the container to restart, `Requires=` to cascade-stop the app,
# and switch-to-configuration to never bring the app back (because its own
# trigger hash didn't change). Silent failure mode, hard to notice without
# monitoring.
{
  pkgs,
  name,
  hostNum,
  dataDir,
  passwordFile, # host-side path to dotenv containing POSTGRES_PASSWORD; bindmounted into container
  pgPackage ? pkgs.postgresql_16,
  extensions ? (_ps: []),
  pgSettings ? {},
  postStartSQL ? null,
  postStartSQLByDatabase ? {},
  # Additional databases to ensure on top of `name`. Useful when a service
  # connects with user=<name> but expects a differently-named database
  # (e.g. jellystat: user=jellystat, database=jfstat). All extra databases
  # are created with `name` as the owner.
  extraDatabases ? [],
  # Schema-ownership allow-list for the invariant assertion. Tables, views,
  # materialized views, sequences, foreign tables and indexes in `public`
  # MUST be owned by the service role `name`; anything not in this list will
  # fail the container startup. Names that don't exist are ignored — list
  # legitimate exceptions (extension-owned data tables, sequences/indexes
  # supporting them) here so genuine drift surfaces as a container-start
  # failure. See issue #250 for the asset_edit_audit incident that drove this.
  ownershipAllowList ? [],
}: let
  hostAddress = "192.168.100.${toString (hostNum * 2)}";
  localAddress = "192.168.100.${toString (hostNum * 2 + 1)}";

  # Path inside the container where the bindmounted password file appears.
  pgpassPath = "/run/secrets/pgpass.env";
  pgpassRuntimePath = "/run/postgresql-${name}-pgpass.env";

  # Schema-ownership invariant. Runs on every database in this instance
  # after init. RAISE EXCEPTION fails the psql step → fails postgresql-setup
  # → fails container start → fires existing container@<name>-db.service alert.
  allowListSql =
    if ownershipAllowList == []
    then "ARRAY[]::text[]"
    else "ARRAY[" + (pkgs.lib.concatMapStringsSep "," (s: "'${s}'") ownershipAllowList) + "]::text[]";

  ownershipInvariantSql = ''
    DO $invariant$
    DECLARE
      bad_objects text;
    BEGIN
      SELECT string_agg(
        c.relkind::text || ':' || c.relname || ' (owner=' || c.relowner::regrole::text || ')',
        E'\n  '
        ORDER BY c.relkind, c.relname
      )
      INTO bad_objects
      FROM pg_class c
      JOIN pg_namespace n ON c.relnamespace = n.oid
      WHERE n.nspname = 'public'
        AND c.relkind IN ('r','v','m','S','f','i')
        AND c.relowner::regrole::text <> '${name}'
        AND c.relname <> ALL(${allowListSql});
      IF bad_objects IS NOT NULL THEN
        RAISE EXCEPTION E'schema-ownership invariant violated; objects in public not owned by service role and not in ownershipAllowList:\n  %', bad_objects
          USING HINT = 'Either ALTER ... OWNER TO the service role (drift) or add the object name to ownershipAllowList (legitimate).';
      END IF;
    END
    $invariant$;
  '';
in {
  inherit hostAddress localAddress;
  dbHost = localAddress;
  dbPort = 5432;
  dbUri = "postgresql://${name}@${localAddress}:5432/${name}";

  containerConfig = {
    autoStart = true;
    privateNetwork = true;
    inherit hostAddress localAddress;

    bindMounts = {
      "/var/lib/postgresql" = {
        hostPath = "${dataDir}/postgres";
        isReadOnly = false;
      };
      ${pgpassPath} = {
        hostPath = passwordFile;
        isReadOnly = true;
      };
    };

    config = {lib, ...}: {
      # Match host locale so imported PG data directories work
      i18n.supportedLocales = ["en_GB.UTF-8/UTF-8" "en_AU.UTF-8/UTF-8" "en_US.UTF-8/UTF-8"];

      services.postgresql = {
        enable = true;
        package = pgPackage;
        enableTCPIP = true;
        inherit extensions;
        settings = pgSettings;
        ensureDatabases = [name] ++ extraDatabases;
        ensureUsers = [
          {
            inherit name;
            ensureDBOwnership = true;
          }
        ];
        # See header comment for the threat model and #232 for the verification.
        # `peer` for local Unix socket = always-available superuser backdoor for
        # ops work via `machinectl shell`. `scram-sha-256` for TCP from host-side
        # veth = consumer must authenticate; superuser is unreachable over TCP.
        authentication = lib.mkForce ''
          local all all peer
          host all ${name} ${hostAddress}/32 scram-sha-256
        '';
      };

      # postgresql-setup runs ensureDatabases/ensureUsers, then our own steps:
      #   0. Copy the root-readable bindmounted pgpass into a private runtime
      #      file owned by postgres.
      #   1. Re-own extra databases to ${name} (ensureDBOwnership only handles primary)
      #   2. Apply postStartSQL if provided, plus per-database init SQL
      #   3. Set the user's password from the private runtime pgpass file
      #   4. Assert schema-ownership invariant on every database (LAST — must
      #      see the post-init state. Failure → fail container start so the
      #      existing container@${name}-db.service Kuma monitor alerts.
      #      See issue #250 for the asset_edit_audit incident that drove this.)
      #
      # The password step uses psql's `:'pwd'` variable interpolation which
      # properly quotes/escapes the value — safe regardless of password contents.
      systemd.services.postgresql-setup.serviceConfig.ExecStartPre = [
        "+${pkgs.writeShellScript "${name}-prepare-pgpass" ''
          set -eu
          ${pkgs.coreutils}/bin/install -m 0400 -o postgres -g postgres ${pgpassPath} ${pgpassRuntimePath}
        ''}"
      ];

      systemd.services.postgresql-setup.serviceConfig.ExecStartPost =
        (map (db: ''${lib.getExe' pgPackage "psql"} -d "${db}" -c "ALTER DATABASE \"${db}\" OWNER TO \"${name}\""'') extraDatabases)
        ++ lib.optional (postStartSQL != null)
        ''${lib.getExe' pgPackage "psql"} -d "${name}" -f "${pkgs.writeText "${name}-pg-init.sql" postStartSQL}"''
        ++ lib.flatten (
          lib.mapAttrsToList (
            db: sql:
              lib.optional (sql != null)
              ''${lib.getExe' pgPackage "psql"} -d "${db}" -f "${pkgs.writeText "${name}-${db}-pg-init.sql" sql}"''
          )
          postStartSQLByDatabase
        )
        ++ [
          (pkgs.writeShellScript "${name}-set-password" ''
            set -eu
            PASS=$(${pkgs.gnugrep}/bin/grep '^POSTGRES_PASSWORD=' ${pgpassRuntimePath} | ${pkgs.coreutils}/bin/cut -d= -f2-)
            if [ -z "$PASS" ]; then
              echo "${name}-set-password: POSTGRES_PASSWORD not found in ${pgpassRuntimePath}" >&2
              exit 1
            fi
            # Escape any single quote in the password by doubling it, for SQL
            # string-literal context. Done via bash parameter expansion to keep
            # the Nix source free of literal double-single-quote sequences,
            # which Nix would otherwise treat as the end of the indented string.
            # Our hex generator can't produce quotes; this stays defensive.
            # Note: psql's :var interpolation does NOT work with -c — only in
            # interactive or -f file mode.
            PASS_ESC=''${PASS//\'/\'\'}
            ${lib.getExe' pgPackage "psql"} -d "${name}" \
              -tAc "ALTER USER \"${name}\" WITH PASSWORD '$PASS_ESC'"
          '')
        ]
        # Schema-ownership invariant — runs LAST, against every database in
        # this instance. Any object in `public` not owned by ${name} and not
        # in `ownershipAllowList` raises an exception → container start fails.
        ++ (map (db: ''${lib.getExe' pgPackage "psql"} -d "${db}" -v ON_ERROR_STOP=1 -f "${pkgs.writeText "${name}-${db}-ownership-invariant.sql" ownershipInvariantSql}"'') ([name] ++ extraDatabases));

      networking.firewall.allowedTCPPorts = [5432];

      # NixOS containers need this or DNS resolution fails (nixpkgs #162686)
      networking.useHostResolvConf = lib.mkForce false;
      services.resolved.enable = true;

      system.stateVersion = "25.05";
    };
  };
}
