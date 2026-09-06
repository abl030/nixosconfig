# UniFi Network controller (on doc2), running natively on NixOS with a
# native MongoDB 8.0 Community Edition server built from the official Ubuntu
# 24.04 precompiled archive. The package updater and migration runbook are
# documented in docs/wiki/services/unifi-mongodb80-native.md (with controller
# history and proxy/device gotchas in unifi-controller.md).
#
# MongoDB is intentionally NOT taken from the default `services.mongodb.package`
# or `services.unifi.mongodbPackage`: nixpkgs' default MongoDB is a source build,
# which previously OOM-killed the doc1 linker. `pkgs.mongodb80` is the only
# server package in this module and is repackaged with autoPatchelfHook.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.unifiController;
  mcfg = cfg.mongodb;

  mongoPackage = pkgs.mongodb80;
  mongodbVersion = mongoPackage.version;
  mongoshBin = lib.getExe pkgs.mongosh;

  mongoRootUser = config.sops.secrets."unifi-mongodb/root-username".path;
  mongoRootPass = config.sops.secrets."unifi-mongodb/root-password".path;
  mongoAppUser = config.sops.secrets."unifi-mongodb/app-username".path;
  mongoAppPass = config.sops.secrets."unifi-mongodb/app-password".path;

  # UniFi's own persistent config file. UniFi requires the application
  # credential inline in a mongodb:// URI; it has no *_FILE indirection. The
  # renderer writes this at runtime as 0600 unifi:unifi, never to the Nix store.
  systemProperties = "${cfg.dataDir}/data/system.properties";
  # Byte-for-byte copy of the pre-native controller configuration. Keep this
  # name distinct from the historical `.pre-external-mongodb` copy created by
  # the old embedded-to-container migration; that older file is not a native
  # 8.0 rollback target.
  systemPropertiesBackup = "${systemProperties}.pre-native-mongodb80";

  # This marker predates the native cutover and proves that the embedded UniFi
  # database was already migrated into the external database namespace. The
  # native cutover must not remove it: it gates UniFi until the existing
  # external-DB configuration is known to contain the application data.
  migrationMarker = "${cfg.dataDir}/migrated-to-external-mongodb";
  legacyDbPath = "${cfg.dataDir}/data/db";

  dataDatabases = [
    mcfg.databaseName
    "${mcfg.databaseName}_stat"
    "${mcfg.databaseName}_audit"
  ];
  roleDatabases = dataDatabases ++ ["${mcfg.databaseName}_restore"];
  probeCollection = "_homelab_probe";

  # The upstream UniFi module always bind-mounts mongodbPackage/bin over the
  # controller's state/bin. In external-DB mode UniFi must not have a mongod
  # there: an empty bin is a deliberate fail-closed stand-in if system.properties
  # is ever lost or the controller falls back to its embedded defaults.
  mongodbAbsent =
    pkgs.runCommand "unifi-mongodb-absent" {
      meta.description = "Empty stand-in for services.unifi.mongodbPackage; UniFi uses native external MongoDB";
    } ''
      mkdir -p "$out/bin"
    '';

  # Keep the complete upstream Logback configuration, but replace its shared
  # file-appender pattern with a message+throwable redaction converter. This
  # prevents MongoDB URI userinfo from reaching local files before they are
  # shipped or inspected.
  unifiLogbackConfig =
    pkgs.runCommand "unifi-logback-redacted.xml" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      python3 - ${lib.escapeShellArg "${config.services.unifi.unifiPackage}/lib/ace.jar"} "$out" <<'PY'
      from pathlib import Path
      from zipfile import ZipFile
      import sys

      source, destination = map(Path, sys.argv[1:])
      pattern = r"%replace(%message %ex){'(?i)(mongodb(?:\+srv)?://)[^\s/@]*@','$1REDACTED@'}%n"
      original = " - %message%n"

      with ZipFile(source) as jar:
          configuration = jar.read("logback.xml").decode("utf-8")

      if configuration.count(original) != 1:
          raise SystemExit("unexpected UniFi logback.xml pattern")

      destination.write_text(configuration.replace(original, " - " + pattern, 1), encoding="utf-8")
      PY
    '';

  # Secret values are generated as alphanumeric strings. UniFi embeds them
  # verbatim in its URI, and the mongosh scripts below bind them through STDIN;
  # this runtime assertion keeps a hand-rotated value from becoming syntax or
  # URI injection.
  assertAlnum = ''
    assert_alnum() {
      case "$2" in
        "") echo "unifi-mongodb: $1 is empty" >&2; exit 2 ;;
        *[!A-Za-z0-9]*)
          echo "unifi-mongodb: $1 contains characters outside [A-Za-z0-9]." >&2
          echo "  UniFi embeds it verbatim in a mongodb:// URI; use an alphanumeric value." >&2
          exit 2 ;;
      esac
    }
  '';

  redactFn = ''
    redact() {
      local text="$1"
      local secret
      for secret in "$root_user" "$root_pass" "$app_user" "$app_pass"; do
        [ -n "$secret" ] || continue
        text="''${text//"$secret"/<redacted>}"
      done
      printf '%s' "$text"
    }
  '';

  # --file /dev/stdin uses script mode, not the REPL (which can exit zero on
  # an uncaught exception). No credential is placed in argv or in a
  # systemd Environment= entry. `both` is needed for role provisioning: it
  # authenticates as ROOT and then creates/updates the APP user.
  mongoshHelpers = ''
    mongosh_script() {
      # $1 = root|app|both, $2 = JS body.
      case "$1" in
        root|both)
          printf 'var ROOT_USER = "%s", ROOT_PASS = "%s";\n' "$root_user" "$root_pass" ;;
      esac
      case "$1" in
        app|both)
          printf 'var APP_USER = "%s", APP_PASS = "%s";\n' "$app_user" "$app_pass" ;;
      esac
      printf '%s\n' "$2"
    }
  '';

  readinessJs = ''
    (function () {
      var admin = db.getSiblingDB("admin");
      try {
        var unauthenticated = admin.runCommand({ listDatabases: 1 });
        if (unauthenticated.ok === 1) {
          print("access control is not enforced");
          quit(10);
        }
      } catch (e) {
        // An unauthorized response is the expected result before auth.
      }
      try {
        if (!admin.auth(ROOT_USER, ROOT_PASS)) {
          print("root authentication returned false");
          quit(11);
        }
        if (admin.runCommand({ ping: 1 }).ok !== 1) {
          print("authenticated ping failed");
          quit(12);
        }
        if (db.version() !== "${mongodbVersion}") {
          print("unexpected running MongoDB version: " + db.version());
          quit(16);
        }
      } catch (e) {
        print("root authentication failed: " + e.message);
        quit(11);
      }
      quit(0);
    })()
  '';

  ensureRoleJs = ''
    (function () {
      var admin = db.getSiblingDB("admin");
      try {
        if (!admin.auth(ROOT_USER, ROOT_PASS)) {
          print("root authentication returned false");
          quit(11);
        }
      } catch (e) {
        print("root authentication failed: " + e.message);
        quit(11);
      }
      var roles = [
        { role: "clusterMonitor", db: "admin" },
        ${lib.concatMapStringsSep ",\n        " (db: ''{ role: "dbOwner", db: "${db}" }'') roleDatabases}
      ];
      try {
        if (admin.getUser(APP_USER) === null) {
          admin.createUser({ user: APP_USER, pwd: APP_PASS, roles: roles });
        } else {
          admin.updateUser(APP_USER, { pwd: APP_PASS, roles: roles });
        }
      } catch (e) {
        print("could not ensure the application role: " + e.message);
        quit(13);
      }
      quit(0);
    })()
  '';

  # Insert/read/delete as the application role. This is used by both the local
  # verifier and the recurring deep probe, and catches auth, write permission,
  # read-only storage, and disk-full failures rather than only process liveness.
  appProbeJs = ''
    (function () {
      var dbName = "${mcfg.databaseName}";
      var collectionName = "${probeCollection}";
      try {
        if (!db.getSiblingDB("admin").auth(APP_USER, APP_PASS)) {
          print("application authentication returned false");
          quit(11);
        }
        var collection = db.getSiblingDB(dbName).getCollection(collectionName);
        var id = new ObjectId();
        var inserted = collection.insertOne({ _id: id, probe: "unifi-mongodb" });
        if (inserted.acknowledged !== true) {
          print("probe insert was not acknowledged");
          quit(12);
        }
        var found = collection.findOne({ _id: id });
        if (found === null) {
          print("probe read did not find the inserted document");
          quit(13);
        }
        var removed = collection.deleteOne({ _id: id });
        if (removed.deletedCount !== 1) {
          print("probe delete did not remove the inserted document");
          quit(14);
        }
        print("UNIFI_MONGO_PROBE_OK");
      } catch (e) {
        print("application write-path failed: " + e.message);
        quit(15);
      }
      quit(0);
    })()
  '';

  renderSystemProperties = pkgs.writeShellApplication {
    name = "unifi-mongodb-render-system-properties";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.util-linux];
    text = ''
      ${assertAlnum}

      # Read the protected app credential as root, then drop privilege BEFORE
      # touching controller-owned paths. A compromised UniFi can replace those
      # paths with symlinks; it must not turn this renderer into a root reader
      # or writer. Pass values through a pipe, never argv or environment.
      if [ "$#" -eq 0 ]; then
        app_user="$(cat ${lib.escapeShellArg mongoAppUser})"
        app_pass="$(cat ${lib.escapeShellArg mongoAppPass})"
        assert_alnum "app username" "$app_user"
        assert_alnum "app password" "$app_pass"
        printf '%s\n' "$app_user" "$app_pass" | setpriv \
          --reuid=unifi --regid=unifi --clear-groups \
          --inh-caps=-all --ambient-caps=-all "$0" --unprivileged
        exit 0
      fi
      [ "$#" -eq 1 ] && [ "$1" = --unprivileged ] || exit 2
      IFS= read -r app_user
      IFS= read -r app_pass
      assert_alnum "app username" "$app_user"
      assert_alnum "app password" "$app_pass"

      install -d -m 0700 ${lib.escapeShellArg (dirOf systemProperties)}

      # Preserve the pre-native/external file exactly once for an operator-led
      # rollback of the controller configuration. Never overwrite this copy.
      if [ -f ${lib.escapeShellArg systemProperties} ] && [ ! -f ${lib.escapeShellArg systemPropertiesBackup} ]; then
        install -m 0600 \
          ${lib.escapeShellArg systemProperties} ${lib.escapeShellArg systemPropertiesBackup}
      fi

      tmp="$(mktemp ${lib.escapeShellArg systemProperties}.XXXXXX)"
      trap 'rm -f "$tmp"' EXIT
      if [ -f ${lib.escapeShellArg systemProperties} ]; then
        rc=0
        grep -vE '^(db\.mongo\.local|db\.mongo\.uri|statdb\.mongo\.uri|unifi\.db\.name)=' \
          ${lib.escapeShellArg systemProperties} > "$tmp" || rc=$?
        [ "$rc" -le 1 ] || exit "$rc"
      fi
      # printf is a bash builtin in this writeShellApplication. The credential
      # therefore never becomes argv for an external process; it is written only
      # to the 0600 runtime file.
      {
        printf '%s\n' \
          'db.mongo.local=false' \
          'unifi.db.name=${mcfg.databaseName}'
        printf '%s%s%s%s\n' \
          "db.mongo.uri=mongodb://$app_user:" \
          "$app_pass" \
          "@127.0.0.1:${toString mcfg.port}/${mcfg.databaseName}?authSource=admin" \
          ""
        printf '%s%s%s%s\n' \
          "statdb.mongo.uri=mongodb://$app_user:" \
          "$app_pass" \
          "@127.0.0.1:${toString mcfg.port}/${mcfg.databaseName}_stat?authSource=admin" \
          ""
      } >> "$tmp"
      chmod 0600 "$tmp"
      mv "$tmp" ${lib.escapeShellArg systemProperties}
      trap - EXIT
    '';
  };

  # Native setup is deliberately separate from the database daemon. It waits
  # for the authenticated native server, refreshes the UniFi role, and only
  # renders system.properties after the pre-existing external migration marker
  # is present. It never changes FCV; that is an explicit operator step after
  # the 7→8.0 burn-in described in the wiki.
  mongoSetup = pkgs.writeShellApplication {
    name = "unifi-mongodb-setup";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.systemd];
    text = ''
      ${assertAlnum}

      root_user="$(cat ${lib.escapeShellArg mongoRootUser})"
      root_pass="$(cat ${lib.escapeShellArg mongoRootPass})"
      app_user="$(cat ${lib.escapeShellArg mongoAppUser})"
      app_pass="$(cat ${lib.escapeShellArg mongoAppPass})"
      assert_alnum "root username" "$root_user"
      assert_alnum "root password" "$root_pass"
      assert_alnum "app username" "$app_user"
      assert_alnum "app password" "$app_pass"

      ${redactFn}
      ${mongoshHelpers}

      run_mongosh() {
        local rc=0
        MONGOSH_OUT="$(mongosh_script "$1" "$2" \
          | timeout 10s ${mongoshBin} --quiet --norc --host 127.0.0.1 --port ${toString mcfg.port} --file /dev/stdin 2>&1)" || rc=$?
        return "$rc"
      }

      ready=0
      detail="native mongod did not answer"
      deadline=$((SECONDS + ${toString mcfg.startupTimeoutSeconds}))
      while [ "$SECONDS" -lt "$deadline" ]; do
        rc=0
        run_mongosh root ${lib.escapeShellArg readinessJs} || rc=$?
        if [ "$rc" -eq 0 ]; then
          ready=1
          break
        fi
        detail="mongosh exited $rc: $(redact "$MONGOSH_OUT")"
        sleep 1
      done

      if [ "$ready" -ne 1 ]; then
        echo "unifi-mongodb: native MongoDB ${mongodbVersion} did not become ready within ${toString mcfg.startupTimeoutSeconds}s" >&2
        echo "unifi-mongodb: last state: $detail" >&2
        exit 1
      fi

      rc=0
      run_mongosh both ${lib.escapeShellArg ensureRoleJs} || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "unifi-mongodb: failed to ensure the UniFi application role (mongosh exited $rc)" >&2
        echo "unifi-mongodb: $(redact "$MONGOSH_OUT")" >&2
        exit 1
      fi

      if [ -e ${lib.escapeShellArg migrationMarker} ]; then
        ${lib.getExe renderSystemProperties}
      else
        echo "unifi-mongodb: role provisioned; system.properties remains unchanged until the external-DB migration marker exists."
        echo "unifi-mongodb: complete the documented migration/cutover preflight before starting unifi.service."
      fi
    '';
  };

  verifyScript = pkgs.writeShellApplication {
    name = "unifi-mongodb-verify";
    runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.systemd pkgs.iproute2 pkgs.curl];
    text = ''
      ${assertAlnum}

      root_user="$(cat ${lib.escapeShellArg mongoRootUser})"
      root_pass="$(cat ${lib.escapeShellArg mongoRootPass})"
      app_user="$(cat ${lib.escapeShellArg mongoAppUser})"
      app_pass="$(cat ${lib.escapeShellArg mongoAppPass})"
      assert_alnum "root username" "$root_user"
      assert_alnum "root password" "$root_pass"
      assert_alnum "app username" "$app_user"
      assert_alnum "app password" "$app_pass"

      ${redactFn}
      ${mongoshHelpers}

      fails=0
      check() {
        if [ "$2" -eq 0 ]; then
          echo "  PASS  $1"
        else
          echo "  FAIL  $1"
          fails=$((fails + 1))
        fi
      }

      echo "unifi-mongodb-verify:"

      rc=0
      systemctl is-active --quiet mongodb.service || rc=1
      check "mongodb.service is active" "$rc"

      rc=0
      ${mongoPackage}/bin/mongod --version 2>&1 | grep -qF "db version v${mongodbVersion}" || rc=1
      check "native mongod is MongoDB ${mongodbVersion} (protected 8.0 series)" "$rc"

      # The server binds only to the host loopback address. A native listener is
      # visible to ss (unlike rootful Podman's nftables-only publish path).
      rc=0
      listeners="$(ss -Hltn 2>/dev/null | awk '$1 == "LISTEN" && $4 ~ /:${toString mcfg.port}$/ {print $4}' || true)"
      printf '%s\n' "$listeners" | grep -qFx "127.0.0.1:${toString mcfg.port}" || rc=1
      if printf '%s\n' "$listeners" | grep -vFx "127.0.0.1:${toString mcfg.port}" | grep -q .; then
        rc=1
      fi
      check "MongoDB listens on 127.0.0.1:${toString mcfg.port} only" "$rc"

      rc=0
      probe_out="$(mongosh_script root ${lib.escapeShellArg readinessJs} \
        | timeout 10s ${mongoshBin} --quiet --norc --host 127.0.0.1 --port ${toString mcfg.port} --file /dev/stdin 2>&1)" || rc=1
      check "MongoDB authorization is enforced and root authenticates" "$rc"
      [ "$rc" -eq 0 ] || echo "        $(redact "$probe_out")"

      rc=0
      probe_out="$(mongosh_script app ${lib.escapeShellArg appProbeJs} \
        | timeout 10s ${mongoshBin} --quiet --norc --host 127.0.0.1 --port ${toString mcfg.port} --file /dev/stdin 2>&1)" || rc=1
      printf '%s\n' "$probe_out" | grep -qF UNIFI_MONGO_PROBE_OK || rc=1
      check "UniFi application role completes insert/read/delete" "$rc"
      [ "$rc" -eq 0 ] || echo "        $(redact "$probe_out")"

      rc=0
      [ -e ${lib.escapeShellArg migrationMarker} ] || rc=1
      check "external-DB migration marker present" "$rc"

      rc=0
      grep -q '^db\.mongo\.local=false$' ${lib.escapeShellArg systemProperties} 2>/dev/null || rc=1
      # UniFi rewrites this file with Java Properties.store(), escaping colons.
      # Accept both the renderer's initial URI and that equivalent stored form.
      grep -Eq '^db\.mongo\.uri=mongodb\\?://.*@127\.0\.0\.1\\?:${toString mcfg.port}/' ${lib.escapeShellArg systemProperties} 2>/dev/null || rc=1
      grep -q '^unifi\.db\.name=${mcfg.databaseName}$' ${lib.escapeShellArg systemProperties} 2>/dev/null || rc=1
      check "system.properties selects native localhost MongoDB" "$rc"

      rc=0
      [ -f ${lib.escapeShellArg systemPropertiesBackup} ] || rc=1
      check "pre-native system.properties is preserved for rollback" "$rc"

      rc=0
      [ "$(stat -c '%a %U:%G' ${lib.escapeShellArg systemProperties} 2>/dev/null)" = "600 unifi:unifi" ] || rc=1
      check "system.properties is 0600 unifi:unifi" "$rc"

      rc=0
      systemctl is-active --quiet unifi.service || rc=1
      check "unifi.service is active" "$rc"

      rc=0
      curl -ksf --max-time 10 https://127.0.0.1:8443/status | grep -q '"up":true' || rc=1
      check "controller /status reports up" "$rc"

      if [ "$fails" -ne 0 ]; then
        echo "unifi-mongodb-verify: $fails check(s) FAILED" >&2
        exit 1
      fi
      echo "unifi-mongodb-verify: all checks passed"
    '';
  };

  # Preserve the existing external-DB guard. This historical marker is NOT
  # evidence of a fresh 7.0 backup or permission to perform the native cutover.
  migrationGate = pkgs.writeShellScript "unifi-native-mongodb-gate" ''
    if [ -e ${lib.escapeShellArg migrationMarker} ]; then
      exit 0
    fi

    echo "UniFi's external MongoDB migration marker is absent; refusing to start" >&2
    if [ -d ${lib.escapeShellArg legacyDbPath} ] && \
       [ -n "$(${pkgs.coreutils}/bin/ls -A ${lib.escapeShellArg legacyDbPath} 2>/dev/null)" ]; then
      echo "Legacy embedded state remains at ${legacyDbPath}." >&2
    fi
    echo "Complete the backup-first runbook in docs/wiki/services/unifi-mongodb80-native.md." >&2
    exit 1
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
        StateDirectory, so this dir is bind-mounted over it.
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
          Host-local MongoDB dbpath root. The actual native dbpath is
          <dataDir>/db so the current external-container data can be upgraded
          in place after the documented FCV/backup preflight. This must be on
          local-backed virtiofs storage, never NFS/CIFS.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 27117;
        description = "Loopback-only MongoDB port used by UniFi.";
      };

      databaseName = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_]+";
        default = "ace";
        description = "Primary UniFi database name; the existing deployment uses ace.";
      };

      uid = lib.mkOption {
        type = lib.types.int;
        default = 2015;
        description = "Fixed non-root UID owning and running the MongoDB dbpath.";
      };

      gid = lib.mkOption {
        type = lib.types.int;
        default = 2015;
        description = "Fixed non-root GID owning the MongoDB dbpath.";
      };

      startupTimeoutSeconds = lib.mkOption {
        type = lib.types.int;
        default = 180;
        description = "How long the setup unit waits for authenticated MongoDB.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mcfg.uid != 1000 && mcfg.gid != 1000;
        message = "unifi-mongodb must not run as host UID/GID 1000 (abl030 has passwordless sudo)";
      }
      {
        assertion = lib.hasPrefix "8.0." mongodbVersion;
        message = "UniFi MongoDB must stay on the protected MongoDB 8.0 patch series";
      }
      {
        assertion = mcfg.port != 27017;
        message = "UniFi MongoDB must retain its dedicated non-default port";
      }
    ];

    # The native NixOS database module is used for lifecycle/config rendering;
    # auth is enabled in its generated YAML below so it does not attempt the
    # upstream first-start root bootstrap against an already-authenticated data
    # directory. Existing root/app users are verified by unifi-mongodb-setup.
    services.mongodb = {
      enable = true;
      package = mongoPackage;
      mongoshPackage = pkgs.mongosh;
      user = "unifi-mongodb";
      bind_ip = "127.0.0.1";
      dbpath = "${mcfg.dataDir}/db";
      pidFile = "/run/unifi-mongodb/mongod.pid";
      enableAuth = false;
      extraConfig =
        "net.port: ${toString mcfg.port}\n"
        + "security.authorization: "
        + "en"
        + "abled\n";
    };

    users = {
      users.unifi-mongodb = {
        isSystemUser = true;
        inherit (mcfg) uid;
        group = "unifi-mongodb";
        home = mcfg.dataDir;
        description = "UniFi MongoDB native daemon user";
      };
      users.unifi-mongodb-probe = {
        isSystemUser = true;
        group = "unifi-mongodb-probe";
        description = "Least-privilege UniFi MongoDB health-probe user";
      };
      groups.unifi-mongodb.gid = mcfg.gid;
      groups.unifi-mongodb-probe = {};
    };

    environment.systemPackages = [verifyScript mongoPackage pkgs.mongosh];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 unifi unifi -"
      "d ${mcfg.dataDir} 0750 unifi-mongodb unifi-mongodb -"
      "d ${mcfg.dataDir}/db 0750 unifi-mongodb unifi-mongodb -"
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
      # Native mongod does not read these files. Keep the root credential
      # root-only; setup and verification are explicit root service boundaries.
      "unifi-mongodb/root-username" = common "root_username";
      "unifi-mongodb/root-password" = common "root_password";

      # Application credential: only ever read by the setup/verifier root
      # boundary and the dedicated least-privilege deep-probe user.
      "unifi-mongodb/app-username" =
        common "app_username"
        // {
          owner = "unifi-mongodb-probe";
          group = "unifi-mongodb-probe";
        };
      "unifi-mongodb/app-password" =
        common "app_password"
        // {
          owner = "unifi-mongodb-probe";
          group = "unifi-mongodb-probe";
        };
    };

    homelab = {
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

        deepProbes = [
          {
            name = "UniFi MongoDB write-path";
            command = "${pkgs.callPackage ./probes/check-unifi-mongodb.nix {}}/bin/check-unifi-mongodb";
            interval = "5m";
            intervalSecs = 450;
            serviceConfig = {
              User = "unifi-mongodb-probe";
              Group = "unifi-mongodb-probe";
              CapabilityBoundingSet = "";
              AmbientCapabilities = "";
              PrivateDevices = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              Environment = [
                "UNIFI_MONGO_HOST=127.0.0.1"
                "UNIFI_MONGO_PORT=${toString mcfg.port}"
                "UNIFI_MONGO_DB=${mcfg.databaseName}"
                "UNIFI_MONGO_COLLECTION=${probeCollection}"
                "UNIFI_MONGO_USER_FILE=${mongoAppUser}"
                "UNIFI_MONGO_PASSWORD_FILE=${mongoAppPass}"
                "UNIFI_MONGO_MONGOSH=${mongoshBin}"
              ];
            };
          }
        ];

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
            unit = "mongodb.service";
            pattern = "(?i)(Permission denied|Read-only file system|No space left on device|WiredTiger error)";
            severity = "critical";
            summary = "Native UniFi MongoDB cannot write its dbpath — permissions, read-only mount, or disk full";
          }
          {
            name = "UniFi MongoDB authentication failure";
            unit = "unifi-mongodb-setup.service";
            pattern = "(?i)(root authentication failed|failed to ensure the UniFi application role|did not become ready)";
            severity = "critical";
            summary = "UniFi MongoDB setup could not authenticate or provision the application role";
          }
          {
            name = "UniFi MongoDB native cutover gate";
            unit = "unifi.service";
            pattern = "(?i)(external MongoDB migration marker is absent|Legacy embedded state remains)";
            severity = "critical";
            summary = "UniFi remains stopped because its MongoDB migration/cutover marker is absent";
          }
        ];
      };
    };

    systemd.services = {
      # Upstream services.mongodb owns ExecStart; these overrides add
      # the native daemon's persistence, restart-on-failure, and least-privilege
      # envelope without copying its lifecycle implementation.
      mongodb = {
        after = ["network.target"];
        unitConfig.RequiresMountsFor = [mcfg.dataDir];
        restartTriggers = [mongoPackage];
        # Existing-data upgrade only: never delete mongod.lock or bootstrap an
        # empty database. All lifecycle commands run as the database user.
        preStart = lib.mkForce ''
          test -s ${lib.escapeShellArg "${mcfg.dataDir}/db/storage.bson"} || {
            echo "unifi-mongodb: existing database missing; refusing empty initialization" >&2
            exit 1
          }
        '';
        postStart = lib.mkForce "";
        serviceConfig = {
          PermissionsStartOnly = lib.mkForce false;
          Restart = "on-failure";
          RestartSec = "5s";
          RuntimeDirectory = "unifi-mongodb";
          RuntimeDirectoryMode = "0750";
          UMask = "0077";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          BindLogSockets = true;
          ProtectControlGroups = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectClock = true;
          ProtectHostname = true;
          LockPersonality = true;
          RestrictNamespaces = true;
          RestrictSUIDSGID = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          ReadWritePaths = ["${mcfg.dataDir}/db"];
          LimitNOFILE = 64000;
        };
      };

      unifi-mongodb-setup = {
        description = "Verify native MongoDB and provision the UniFi application role";
        after = ["mongodb.service"];
        requires = ["mongodb.service"];
        before = ["unifi.service"];
        restartTriggers = [
          config.systemd.units."mongodb.service".unit
          mongoRootPass
          mongoAppPass
        ];
        unitConfig.RequiresMountsFor = [cfg.dataDir mcfg.dataDir];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          NoNewPrivileges = true;
          ExecStart = lib.getExe mongoSetup;
          TimeoutStartSec = mcfg.startupTimeoutSeconds + 60;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          # Traverse the historical marker and drop to UniFi before rendering.
          CapabilityBoundingSet = ["CAP_DAC_OVERRIDE" "CAP_SETUID" "CAP_SETGID"];
          AmbientCapabilities = "";
          TemporaryFileSystem = "/mnt";
          BindReadOnlyPaths = [cfg.dataDir];
          ReadWritePaths = ["${cfg.dataDir}/data"];
        };
      };

      unifi = {
        after = ["unifi-mongodb-setup.service"];
        requires = ["unifi-mongodb-setup.service"];
        restartTriggers = [
          config.systemd.units."mongodb.service".unit
          mongoAppPass
        ];
        serviceConfig.ExecCondition = migrationGate;
      };
    };

    services.unifi = {
      enable = true;
      openFirewall = true;
      inherit (cfg) maximumJavaHeapSize;
      mongodbPackage = mongodbAbsent;
      extraJvmOptions = [
        "-XX:+UseParallelGC"
        "-Dlogback.configurationFile=${unifiLogbackConfig}"
      ];
    };
  };
}
