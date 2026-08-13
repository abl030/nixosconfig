# UniFi Network controller (on doc2), running natively on NixOS with its
# MongoDB backend in a dedicated, digest-pinned official MongoDB 7 container.
#
# Full model + gotchas — CSRF/Host login bug, the 8080 device-inform port
# conflict, state relocation to /mnt/virtio, the dual-NIC device-inform quirk,
# and the external-MongoDB cutover runbook:
#   docs/wiki/services/unifi-controller.md
#
# WHY the DB moved out of nixpkgs (forgejo #142): the isolated `mongodb-nixpkgs`
# input required a local, unfree, uncached MongoDB *source* build. On 7.0.39 the
# final `mongod` link OOM-killed GNU ld on doc1 (~19 GiB VSZ), wedging the
# nightly rolling update. UniFi's controller is fine natively; only its database
# needed to stop being a from-source Nix package.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.unifiController;
  mcfg = cfg.mongodb;

  mongoRootUser = config.sops.secrets."unifi-mongodb/root-username".path;
  mongoRootPass = config.sops.secrets."unifi-mongodb/root-password".path;
  mongoAppUser = config.sops.secrets."unifi-mongodb/app-username".path;
  mongoAppPass = config.sops.secrets."unifi-mongodb/app-password".path;

  containerName = "unifi-mongodb";
  containerUnit = "podman-${containerName}.service";

  # UniFi's own persistent config file. UniFi requires the database credential
  # inline in a `mongodb://` URI here — there is no *_FILE indirection in the
  # controller. So this file is rendered AT RUNTIME from the sops secrets into
  # the persistent data dir as 0600 unifi:unifi. It is never in the Nix store,
  # never in argv, and never logged. Rendered by mongoSetup, step 3.
  systemProperties = "${cfg.dataDir}/data/system.properties";

  # Marker proving the operator has completed the documented data migration
  # into the external MongoDB. Gate below refuses to start UniFi without it
  # while legacy embedded-Mongo state is still present.
  migrationMarker = "${cfg.dataDir}/migrated-to-external-mongodb";
  legacyDbPath = "${cfg.dataDir}/data/db";

  # UniFi in external-DB mode never spawns mongod: it reads db.mongo.local=false
  # from system.properties and dials the URI instead. Verified against the
  # reference external-Mongo deployment (linuxserver/docker-unifi-network-
  # application), whose image installs ZERO mongodb packages — only jsvc,
  # logrotate, a JRE and unzip.
  #
  # The upstream NixOS module still hard-bind-mounts `${mongodbPackage}/bin`
  # over `${stateDir}/bin`, so the option must point at *something* with a bin/.
  # We give it a deliberately EMPTY one. That is what removes `mongodb-7_0`
  # from doc2's closure (forgejo #142), and it is also fail-closed: if
  # system.properties were ever lost or misrendered, UniFi would fail to find a
  # local mongod and refuse to start, rather than silently initialising a brand
  # new empty embedded database next to the real one.
  mongodbAbsent =
    pkgs.runCommand "unifi-mongodb-absent" {
      meta.description = "Empty stand-in for services.unifi.mongodbPackage; UniFi uses an external MongoDB container";
    } ''
      mkdir -p "$out/bin"
    '';

  # Official Docker MongoDB image (docker-library/mongo), MongoDB 7.0.40,
  # pinned by immutable multi-arch index digest.
  #
  # IMAGE-PIN-OK: this is the fleet's ONE deliberate exception to the
  # no-image-pinning policy (docs/wiki/nixos-service-modules.md "Image trust",
  # .claude/memory/feedback-no-image-pinning.md), authorised on forgejo #142.
  # Rationale: MongoDB is major-version-coupled to the installed UniFi release
  # (UniFi 10.5 runs on the MongoDB 7 series) AND MongoDB refuses to start on a
  # dbpath written by a newer major version, with no downgrade path. An
  # auto-pulled `:latest` would roll the database to MongoDB 8 unattended and
  # take the controller down with an un-downgradable dbpath — i.e. the failure
  # mode here is silent DATA LOSS, not the supply-chain risk the policy trades
  # away. Same class as the schema-coupled mb-solr carve-out. The MongoDB 8
  # move is a tracked, explicit migration, not a nightly pull.
  #
  # Re-pin with:
  #   skopeo inspect docker://docker.io/library/mongo:<ver> | jq -r .Digest
  # `repo:tag@sha256:` is NOT accepted by containers/image — digest only.
  mongodbImage = "docker.io/library/mongo@sha256:444d798458e5aa40f3667230a9c631974fa169c32ae4a2d924658ac72b753122";
  mongodbVersion = "7.0.40";

  # Credentials are constrained to [A-Za-z0-9] by the generator documented in
  # docs/wiki/services/unifi-controller.md. Everything downstream then needs no
  # escaping: no percent-encoding in the mongodb:// URI, no quoting in the
  # mongosh JS. The setup unit asserts the invariant at runtime rather than
  # trusting it, and fails closed.
  assertAlnum = ''
    assert_alnum() {
      case "$2" in
        "") echo "unifi-mongodb: $1 is empty" >&2; exit 2 ;;
        *[!A-Za-z0-9]*)
          echo "unifi-mongodb: $1 contains characters outside [A-Za-z0-9]." >&2
          echo "  UniFi embeds it verbatim in a mongodb:// URI; re-generate it" >&2
          echo "  alphanumeric-only (see docs/wiki/services/unifi-controller.md)." >&2
          exit 2 ;;
      esac
    }
  '';

  podmanBin = lib.getExe' config.virtualisation.podman.package "podman";

  # Ensure the UniFi application role exists with exactly the roles the
  # controller needs, then render system.properties. Idempotent: safe on every
  # boot, and it re-applies a rotated password without a manual mongosh session.
  #
  # Credentials reach mongosh over STDIN (heredoc), never argv and never the
  # unit environment — `podman exec` argv is world-readable via `podman
  # inspect`, and unit Environment= shows up in `systemctl show`.
  mongoSetup = pkgs.writeShellApplication {
    name = "unifi-mongodb-setup";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep config.virtualisation.podman.package];
    text = ''
      ${assertAlnum}

      root_user="$(cat ${lib.escapeShellArg mongoRootUser})"
      root_pass="$(cat ${lib.escapeShellArg mongoRootPass})"
      app_user="$(cat ${lib.escapeShellArg mongoAppUser})"
      app_pass="$(cat ${lib.escapeShellArg mongoAppPass})"

      assert_alnum "root username" "$root_user"
      assert_alnum "root password" "$root_pass"
      assert_alnum "app username"  "$app_user"
      assert_alnum "app password"  "$app_pass"

      # 1. Readiness. `ping` is one of the few commands MongoDB answers before
      #    authentication, so this probes liveness without credentials.
      ready=0
      for _ in $(seq 1 ${toString mcfg.startupTimeoutSeconds}); do
        if ${podmanBin} exec ${containerName} \
             mongosh --quiet --norc --eval 'quit(db.adminCommand({ping:1}).ok ? 0 : 1)' \
             >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 1
      done
      if [ "$ready" -ne 1 ]; then
        echo "unifi-mongodb: mongod did not become ready within ${toString mcfg.startupTimeoutSeconds}s" >&2
        exit 1
      fi

      # 2. Application role. Created in the `admin` authentication database
      #    with the exact role set the UniFi Network Application requires:
      #    clusterMonitor (health checking) plus dbOwner on the primary,
      #    _stat, _audit and _restore databases.
      if ! ${podmanBin} exec -i ${containerName} \
             mongosh --quiet --norc >/dev/null <<EOF
      var admin = db.getSiblingDB("admin");
      try {
        admin.auth("$root_user", "$root_pass");
      } catch (e) {
        print("unifi-mongodb: root authentication failed: " + e.message);
        quit(1);
      }
      var roles = [
        "clusterMonitor",
        { db: "${mcfg.databaseName}",          role: "dbOwner" },
        { db: "${mcfg.databaseName}_stat",     role: "dbOwner" },
        { db: "${mcfg.databaseName}_audit",    role: "dbOwner" },
        { db: "${mcfg.databaseName}_restore",  role: "dbOwner" }
      ];
      try {
        if (admin.getUser("$app_user") === null) {
          admin.createUser({ user: "$app_user", pwd: "$app_pass", roles: roles });
        } else {
          admin.updateUser("$app_user", { pwd: "$app_pass", roles: roles });
        }
      } catch (e) {
        print("unifi-mongodb: could not ensure the application role: " + e.message);
        quit(1);
      }
      quit(0);
      EOF
      then
        echo "unifi-mongodb: failed to ensure the UniFi application role" >&2
        exit 1
      fi

      # 3. system.properties. Preserve every line UniFi or the operator owns;
      #    replace only the four keys that select the database backend.
      install -d -o unifi -g unifi -m 0700 ${lib.escapeShellArg (dirOf systemProperties)}
      tmp="$(mktemp ${lib.escapeShellArg systemProperties}.XXXXXX)"
      trap 'rm -f "$tmp"' EXIT
      if [ -f ${lib.escapeShellArg systemProperties} ]; then
        grep -vE '^(db\.mongo\.local|db\.mongo\.uri|statdb\.mongo\.uri|unifi\.db\.name)=' \
          ${lib.escapeShellArg systemProperties} > "$tmp" || true
      fi
      {
        echo "db.mongo.local=false"
        echo "db.mongo.uri=mongodb://$app_user:$app_pass@127.0.0.1:${toString mcfg.port}/${mcfg.databaseName}?authSource=admin"
        echo "statdb.mongo.uri=mongodb://$app_user:$app_pass@127.0.0.1:${toString mcfg.port}/${mcfg.databaseName}_stat?authSource=admin"
        echo "unifi.db.name=${mcfg.databaseName}"
      } >> "$tmp"
      chown unifi:unifi "$tmp"
      chmod 0600 "$tmp"
      mv "$tmp" ${lib.escapeShellArg systemProperties}
      trap - EXIT
    '';
  };

  # Refuse to start UniFi against the external database while the legacy
  # embedded dbpath still holds data and the operator has not run the
  # documented migration. Starting anyway would bring the controller up
  # EMPTY — an unadopted, factory-looking controller — which is far worse
  # and far less reversible than staying down and paging the Kuma monitor.
  #
  # Same shape as youtarr's OCI→nspawn MariaDB gate.
  migrationGate = pkgs.writeShellScript "unifi-external-mongodb-gate" ''
    if [ -e ${lib.escapeShellArg migrationMarker} ]; then
      exit 0
    fi

    if [ -d ${lib.escapeShellArg legacyDbPath} ] && \
       [ -n "$(ls -A ${lib.escapeShellArg legacyDbPath} 2>/dev/null)" ]; then
      echo "UniFi is configured for the external MongoDB container, but legacy" >&2
      echo "embedded MongoDB state is still present at ${legacyDbPath} and the" >&2
      echo "migration has not been recorded." >&2
      echo "Starting now would bring the controller up against an EMPTY database." >&2
      echo "Run the cutover in docs/wiki/services/unifi-controller.md, then:" >&2
      echo "  touch ${migrationMarker}" >&2
      exit 1
    fi

    exit 0
  '';
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
        Persistent controller state (keystore, autobackups, system.properties).
        The upstream services.unifi module hard-codes /var/lib/unifi via
        StateDirectory, so this dir is bind-mounted over it. Keep it on
        portable, backed-up storage (virtiofs) — never the disposable VM
        root, which is neither portable nor in the backup scope.
      '';
    };

    maximumJavaHeapSize = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = "Maximum UniFi JVM heap in MiB.";
    };

    mongodb = {
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/virtio/unifi-mongodb";
        description = ''
          Host-local persistent MongoDB dbpath. MUST NOT be a network
          filesystem — MongoDB does not support NFS/CIFS for its dbpath.

          /mnt/virtio is virtiofs, a paravirtualised passthrough of prom's
          local `nvmeprom/containers` ZFS dataset — not a network filesystem,
          and where every other doc2 database already lives. It also inherits
          the existing backup path for free: containers-backup.service takes an
          ATOMIC ZFS snapshot of the whole dataset (journal and data files in
          one consistent image, which is exactly what MongoDB requires of a
          volume-snapshot backup), age-encrypts it to tower, and kopia-mum
          ships it offsite.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 27117;
        description = ''
          Host port for MongoDB, published on 127.0.0.1 ONLY. 27117 is the port
          UniFi historically used for its embedded mongod, so operator muscle
          memory and any local tooling keep working; it is free now that the
          embedded instance is gone.
        '';
      };

      databaseName = lib.mkOption {
        type = lib.types.str;
        default = "unifi";
        description = ''
          Primary UniFi database name (`unifi.db.name`). The controller also
          uses <name>_stat, <name>_audit and <name>_restore.

          NOTE: the embedded instance defaulted to `ace`/`ace_stat`. This is one
          reason a raw dbpath handoff is not a safe migration — see the cutover
          runbook.
        '';
      };

      uid = lib.mkOption {
        type = lib.types.int;
        default = 2015;
        description = "Fixed non-root UID that mongod runs as, and that owns the dbpath.";
      };

      gid = lib.mkOption {
        type = lib.types.int;
        default = 2015;
        description = "Fixed non-root GID that mongod runs as, and that owns the dbpath.";
      };

      startupTimeoutSeconds = lib.mkOption {
        type = lib.types.int;
        default = 120;
        description = "How long the setup unit waits for mongod to answer an unauthenticated ping before failing.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mcfg.uid != 1000 && mcfg.gid != 1000;
        message = "unifi-mongodb must not run as host UID/GID 1000 (abl030 has passwordless sudo)";
      }
    ];

    services.unifi = {
      enable = true;
      # openFirewall opens the device-facing ports (inform 8080, STUN 3478,
      # discovery, etc.) that APs/switches need for adoption + check-in. It does
      # NOT open the 8443 UI — that stays on loopback behind homelab.localProxy.
      # It does NOT open MongoDB either: the container publishes to loopback.
      openFirewall = true;
      inherit (cfg) maximumJavaHeapSize;
      mongodbPackage = mongodbAbsent;
      extraJvmOptions = ["-XX:+UseParallelGC"];
    };

    # Dedicated, fixed, non-root identity for mongod. Fixed so the on-disk
    # dbpath ownership survives a rebuild and cannot drift onto another
    # service's UID.
    users = {
      users.unifi-mongodb = {
        isSystemUser = true;
        inherit (mcfg) uid;
        group = "unifi-mongodb";
        home = mcfg.dataDir;
        description = "UniFi MongoDB container runtime user";
      };
      groups.unifi-mongodb.gid = mcfg.gid;
    };

    # Relocate controller state off the disposable VM root onto portable,
    # backed-up virtiofs storage. services.unifi hard-codes /var/lib/unifi
    # (StateDirectory + WorkingDirectory), so bind-mount the real dataDir over
    # it rather than fight the upstream module.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 unifi unifi -"
      # dbpath ownership is explicit and enforced on every boot. The official
      # mongo entrypoint only chowns /data/db when it starts as root; we run it
      # as a fixed non-root UID, so the host side must already be correct.
      "d ${mcfg.dataDir} 0750 unifi-mongodb unifi-mongodb -"
      "d ${mcfg.dataDir}/db 0750 unifi-mongodb unifi-mongodb -"
      "d ${mcfg.dataDir}/configdb 0750 unifi-mongodb unifi-mongodb -"
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

    sops.secrets = let
      common = key: {
        sopsFile = config.homelab.secrets.sopsFile "unifi-mongodb.yaml";
        format = "yaml";
        inherit key;
        mode = "0400";
        restartUnits = ["unifi-mongodb-setup.service"];
      };
    in {
      # Root credential: consumed by the container itself via the official
      # image's *_FILE convention, so it must be readable by the container UID.
      "unifi-mongodb/root-username" =
        common "root_username"
        // {
          owner = "unifi-mongodb";
          group = "unifi-mongodb";
        };
      "unifi-mongodb/root-password" =
        common "root_password"
        // {
          owner = "unifi-mongodb";
          group = "unifi-mongodb";
        };
      # Application credential: only ever read by root-run host units (the
      # setup unit and the deep probe). The container never sees it.
      "unifi-mongodb/app-username" = common "app_username";
      "unifi-mongodb/app-password" = common "app_password";
    };

    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = containerUnit;
          image = mongodbImage;
        }
      ];

      # UI (8443, self-signed HTTPS) surfaced via the nginx localProxy like every
      # other web service. recommendedProxySettings sends `Host: $host`, so
      # UniFi's CSRF/Origin check sees a matching Host and login works — the whole
      # reason the hand-rolled Caddy reverse_proxy 403'd. https+insecureSkipVerify
      # handle the controller's self-signed cert; websocket carries /wss.
      localProxy.hosts = [
        {
          host = cfg.fqdn;
          port = 8443;
          https = true;
          insecureSkipVerify = true;
          websocket = true;
        }
      ];

      monitoring = {
        monitors = [
          {
            name = "UniFi Controller";
            url = "https://${cfg.fqdn}/";
          }
        ];

        # UniFi's write path is now a separate, directly probeable MongoDB
        # instance, so the old "embedded mongod, not worth reaching into"
        # justification for skipping deep probes no longer holds. This probe
        # authenticates as the UniFi application role and round-trips a real
        # write, which is the failure class the shallow UI monitor misses:
        # container up but auth broken, dbpath read-only, or disk full.
        deepProbes = [
          {
            name = "UniFi MongoDB write-path";
            command = "${pkgs.callPackage ./probes/check-unifi-mongodb.nix {}}/bin/check-unifi-mongodb";
            interval = "5m";
            intervalSecs = 450;
            serviceConfig = {
              Environment = [
                "UNIFI_MONGO_CONTAINER=${containerName}"
                "UNIFI_MONGO_DB=${mcfg.databaseName}"
                "UNIFI_MONGO_USER_FILE=${mongoAppUser}"
                "UNIFI_MONGO_PASSWORD_FILE=${mongoAppPass}"
                "UNIFI_MONGO_PODMAN=${podmanBin}"
              ];
            };
          }
        ];

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
          {
            name = "UniFi MongoDB unable to write";
            unit = containerUnit;
            # WiredTiger surfaces dbpath ownership/permission and disk-full
            # failures here. This is the UID-mismatch class the youtarr MariaDB
            # pattern catches, plus the storage-exhaustion case.
            pattern = "(?i)(Permission denied|Read-only file system|No space left on device|WiredTiger error)";
            severity = "critical";
            summary = "UniFi MongoDB can't write its dbpath — permissions, read-only mount, or disk full";
          }
          {
            name = "UniFi MongoDB authentication failure";
            unit = "unifi-mongodb-setup.service";
            pattern = "(?i)(root authentication failed|failed to ensure the UniFi application role|did not become ready)";
            severity = "critical";
            summary = "UniFi MongoDB setup could not authenticate or provision the application role";
          }
        ];
      };
    };

    virtualisation.oci-containers.containers.${containerName} = {
      image = mongodbImage;
      autoStart = true;
      # Digest references are immutable, so this resolves once and never
      # silently rolls the database forward. The podman-update-containers timer
      # re-pulls the same digest and correctly reports "unchanged".
      pull = "missing";
      # Loopback only. Native UniFi shares the host network namespace
      # (PrivateNetwork=false), so 127.0.0.1 reaches this; nothing on the LAN
      # or the tailnet can. Combined with the dedicated isolated-<name> bridge
      # that homelab.podman assigns, no sibling container can reach it either.
      ports = ["127.0.0.1:${toString mcfg.port}:27017"];
      # mongod must listen on all of the CONTAINER's interfaces or podman's
      # port publishing cannot reach it — the container's own loopback is not
      # what podman forwards to. Host-side exposure is bounded by the 127.0.0.1
      # publish above, not by mongod's bind. --auth is explicit rather than
      # relying on the entrypoint inferring it from the root credential.
      cmd = ["mongod" "--auth" "--bind_ip_all"];
      # A digest is opaque at the console. Record the human-readable version it
      # resolves to so `podman inspect`/`podman ps --format '{{.Labels}}'` answers
      # "which MongoDB is this?" without a registry round-trip.
      labels."au.ablz.mongodb-version" = mongodbVersion;
      environment = {
        # *_FILE indirection: the credential value itself never enters the unit
        # environment, where `systemctl show` would expose it.
        MONGO_INITDB_ROOT_USERNAME_FILE = "/run/secrets/unifi-mongodb-root-username";
        MONGO_INITDB_ROOT_PASSWORD_FILE = "/run/secrets/unifi-mongodb-root-password";
      };
      volumes = [
        "${mcfg.dataDir}/db:/data/db:rw"
        "${mcfg.dataDir}/configdb:/data/configdb:rw"
        "${mongoRootUser}:/run/secrets/unifi-mongodb-root-username:ro"
        "${mongoRootPass}:/run/secrets/unifi-mongodb-root-password:ro"
      ];
      # Plain mongod on an unprivileged port as a fixed non-root UID: it needs
      # no Linux capabilities at all. The entrypoint's chown/gosu branch only
      # runs when it starts as root, which --user prevents, so the dbpath is
      # pre-owned by systemd-tmpfiles above instead.
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--user=${toString mcfg.uid}:${toString mcfg.gid}"
        ];
    };

    systemd.services = {
      # NNP-OK: this unit runs as root to write system.properties as unifi:unifi
      # and to drive podman; NoNewPrivileges is set on it regardless (below),
      # and the container itself is hardened at the podman layer via
      # homelab.podman.hardenOptions.
      unifi-mongodb-setup = {
        description = "Provision the UniFi MongoDB role and render system.properties";
        after = [containerUnit];
        requires = [containerUnit];
        # Pulled in by unifi.service's Requires= below. That still happens when
        # the migration gate skips unifi itself (dependencies are started before
        # ExecCondition runs), so the role and system.properties are provisioned
        # and ready for the operator's cutover even while UniFi stays down.
        before = ["unifi.service"];
        restartTriggers = [
          config.systemd.units.${containerUnit}.unit
          mongoRootPass
          mongoAppPass
        ];
        unitConfig.RequiresMountsFor = [cfg.dataDir mcfg.dataDir];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          NoNewPrivileges = true;
          ExecStart = lib.getExe mongoSetup;
          # doc2 default (#257): blank tmpfs over /mnt, bind back only the
          # controller state dir this unit actually writes into.
          TemporaryFileSystem = "/mnt";
          BindPaths = [cfg.dataDir];
        };
      };

      unifi = {
        after = ["unifi-mongodb-setup.service"];
        requires = ["unifi-mongodb-setup.service"];
        # Host-side unit wrapper, NOT the container's inner definition — a
        # Requires= dependency that is not restart-triggered gets cascade-stopped
        # and never brought back. See mk-pg-container.nix's header.
        restartTriggers = [
          config.systemd.units.${containerUnit}.unit
          mongoAppPass
        ];
        serviceConfig.ExecCondition = migrationGate;
      };
    };
  };
}
