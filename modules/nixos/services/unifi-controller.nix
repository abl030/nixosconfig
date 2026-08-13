# UniFi Network controller (on doc2), running natively on NixOS with its
# MongoDB backend in a dedicated, digest-pinned official MongoDB 7 container.
#
# Full model + gotchas — CSRF/Host login bug, the 8080 device-inform port
# conflict, state relocation to /mnt/virtio, the dual-NIC device-inform quirk,
# and the external-MongoDB migration runbook:
#   docs/wiki/services/unifi-controller.md
#
# WHY the DB moved out of nixpkgs (forgejo #142): the isolated `mongodb-nixpkgs`
# input required a local, unfree, uncached MongoDB *source* build. On 7.0.39 the
# final `mongod` link OOM-killed GNU ld on doc1 (~19 GiB VSZ), wedging the
# nightly rolling update. UniFi's controller is fine natively; only its database
# needed to stop being a from-source Nix package.
#
# WHY THIS IS THE SECOND ATTEMPT (PR #144 was merged, deployed, and reverted by
# c2c2789b on 2026-08-13): the first cutover pointed a controller with a
# PERSISTENT data dir at a FRESH external database and then tried to restore a
# `.unf` backup through the first-run setup wizard. The wizard never appeared —
# `is_setup_completed=true` lives in the on-disk `system.properties`, not in the
# database — so the fresh DB had no admin, `POST /upload/backup` returned 401,
# and the restore was unreachable. `.unf` files are encrypted archives only the
# controller can consume, so there was no offline way in either.
#
# This module migrates the DATABASE CONTENTS instead (mongodump/mongorestore
# under the SAME namespaces). That carries `ace.admin` along with every site,
# device, setting and statistic, needs no wizard, no browser upload and no new
# keystore — and it is the only mechanism whose end state was reproduced from
# this network's own data before being proposed.
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
  # Throwaway instance that serves a COPY of the legacy embedded dbpath during
  # the migration. Never started automatically, never published, --network=none.
  sourceContainer = "unifi-mongodb-migration";

  # UniFi's own persistent config file. UniFi requires the database credential
  # inline in a `mongodb://` URI here — there is no *_FILE indirection in the
  # controller. So this file is rendered AT RUNTIME from the sops secrets into
  # the persistent data dir as 0600 unifi:unifi. It is never in the Nix store,
  # never in argv, and never logged.
  systemProperties = "${cfg.dataDir}/data/system.properties";
  # Byte-for-byte copy of system.properties as it was BEFORE this module first
  # rewrote it. Written once, never overwritten. This is what makes rollback an
  # exact restore rather than "remember to hand-edit four keys back" — the gap
  # that would have silently pointed the rolled-back embedded controller at the
  # empty external database during the first attempt.
  systemPropertiesBackup = "${systemProperties}.pre-external-mongodb";

  # Marker proving the operator has completed the documented data migration.
  # Written by unifi-mongodb-migrate.service only after the restore verified.
  migrationMarker = "${cfg.dataDir}/migrated-to-external-mongodb";
  legacyDbPath = "${cfg.dataDir}/data/db";

  # Host-local scratch for the migration: a copy of the legacy dbpath plus the
  # dump taken from it. Kept after the cutover as a fast local restore point.
  migrationDir = "${mcfg.dataDir}/migration";
  legacyCopy = "${migrationDir}/legacy-db";
  dumpDir = "${migrationDir}/dump";
  dumpArchive = "${dumpDir}/unifi.archive";
  sourceCounts = "${migrationDir}/source-counts.txt";

  # The databases UniFi actually stores data in, and therefore the ones the
  # migration carries. `unifi.db.name` selects the base name; the controller
  # derives <name>_stat, <name>_audit and (transiently) <name>_restore from it.
  dataDatabases = [
    mcfg.databaseName
    "${mcfg.databaseName}_stat"
    "${mcfg.databaseName}_audit"
  ];
  # The application role is granted dbOwner on all four, including _restore,
  # which UniFi creates on demand when restoring a backup through the UI.
  roleDatabases = dataDatabases ++ ["${mcfg.databaseName}_restore"];

  # Collection the deep probe round-trips through. Excluded from every count
  # comparison so a probe run between deploy and cutover cannot make the target
  # look "non-empty" or shift a number.
  probeCollection = "_homelab_probe";

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

  podmanBin = lib.getExe' config.virtualisation.podman.package "podman";

  # ---------------------------------------------------------------------------
  # Shared shell fragments
  # ---------------------------------------------------------------------------

  # Credentials are constrained to [A-Za-z0-9] by the generator documented in
  # docs/wiki/services/unifi-controller.md. Everything downstream then needs no
  # escaping: no percent-encoding in the mongodb:// URI, no quoting in the
  # mongosh JS. Assert the invariant at runtime rather than trusting it, and
  # fail closed.
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

  # Diagnostics from mongosh are KEPT — the first attempt discarded them with
  # `>/dev/null`, so a role-provisioning failure surfaced only as a generic
  # message — but scrubbed of every credential value first. Pure bash parameter
  # expansion: putting a secret in `sed`'s argv would defeat the point.
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

  # mongosh scripts are fed on STDIN — never argv, which `podman inspect`
  # exposes — with the credentials prepended as `var` bindings. `printf` is a
  # bash builtin, so the value never becomes process argv on the way in.
  #
  # Two hard-won rules are encoded in the JS below:
  #   1. Every fallible call is wrapped in try/catch and every path ends in an
  #      explicit quit(). An UNCAUGHT throw in a stdin-fed mongosh script exits
  #      **0**, so a gate written as `if (!admin.auth(u, p)) quit(1)` reports
  #      READY on a bad credential (db.auth() throws, it does not return false).
  #      Verified against mongosh 2.9.
  #   2. Output rows carry a `UNIFICOUNT ` marker and are extracted with
  #      `grep -o`. A stdin-fed mongosh is a REPL: it interleaves `test>`
  #      prompts and spinner characters with the script's own output, and an
  #      anchored `^` match silently drops the first row.
  mongoshHelpers = ''
    mongosh_script() {
      # $1 = root|app, $2 = JS body. Emits the script on stdout.
      if [ "$1" = "root" ]; then
        printf 'var ROOT_USER = "%s", ROOT_PASS = "%s";\n' "$root_user" "$root_pass"
      else
        printf 'var APP_USER = "%s", APP_PASS = "%s";\n' "$app_user" "$app_pass"
      fi
      printf '%s\n' "$2"
    }

    parse_counts() {
      grep -oE 'UNIFICOUNT [A-Za-z0-9_]+\.[A-Za-z0-9_]+=[0-9]+' \
        | sed 's/^UNIFICOUNT //' | sort
    }
  '';

  # Readiness: refuse everything except the FINAL, authenticated mongod.
  #
  # The official image's docker-entrypoint.sh runs a temporary mongod while it
  # creates the root user on an empty dbpath and — verified by reading the
  # entrypoint out of the pinned 7.0.40 image, lines 306-312 — forces
  # `--bind_ip 127.0.0.1`, strips `--bind_ip_all`, and strips `--auth` for it.
  # An unauthenticated `ping`, which is what the first attempt waited for, is
  # answered by that temporary server; it then shuts down mid-provisioning.
  # That is exactly what failed on 2026-08-13 at 08:33:31.
  #
  # Two structural discriminators, neither of them timing-based:
  #   * access control must be ENFORCED — an unauthenticated privileged command
  #     must be refused. Only the final `--auth` mongod does that, and it stays
  #     true even after the temporary server has created the root user.
  #   * the root credential must authenticate.
  # The caller adds a third: the published loopback socket — the exact one
  # UniFi dials — must accept a connection, which a container-loopback-only
  # server structurally cannot satisfy.
  readinessJs = ''
    (function () {
      var admin = db.getSiblingDB("admin");
      var unauth;
      try {
        unauth = admin.runCommand({ listDatabases: 1 });
      } catch (e) {
        unauth = { ok: 0 };
      }
      if (unauth.ok === 1) {
        print("access control is not enforced yet: this is the image's initialisation mongod");
        quit(10);
      }
      try {
        admin.auth(ROOT_USER, ROOT_PASS);
      } catch (e) {
        print("root authentication failed: " + e.message);
        quit(11);
      }
      try {
        if (admin.runCommand({ ping: 1 }).ok !== 1) {
          print("ping failed after authentication");
          quit(12);
        }
      } catch (e) {
        print("ping raised after authentication: " + e.message);
        quit(12);
      }
      quit(0);
    })()
  '';

  # Idempotent application role, in the `admin` authentication database, with
  # the exact role set the UniFi Network Application requires: clusterMonitor
  # (health checking) plus dbOwner on the primary, _stat, _audit and _restore
  # databases. Re-applies a rotated password without a manual mongosh session.
  ensureRoleJs = ''
    (function () {
      var admin = db.getSiblingDB("admin");
      try {
        admin.auth(ROOT_USER, ROOT_PASS);
      } catch (e) {
        print("root authentication failed: " + e.message);
        quit(11);
      }
      var roles = [
        "clusterMonitor",
        ${lib.concatMapStringsSep ",\n        " (db: ''{ db: "${db}", role: "dbOwner" }'') roleDatabases}
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

  # Emit `UNIFICOUNT <db>.<collection>=<count>` for every UniFi collection.
  # Used on both sides of the migration; the deep probe's own collection is
  # skipped so a probe run cannot shift a number.
  #
  # The body is shared rather than composed from two adjacent IIFEs: without a
  # separator, `(function(){})()` followed by `(function(){})()` parses as an
  # attempt to CALL the first one's result. It happens to survive mongosh's
  # line-by-line REPL, which is exactly the kind of accident this migration has
  # already been bitten by once.
  countsBody = ''
    var out = [];
    [${lib.concatMapStringsSep ", " (db: "\"${db}\"") dataDatabases}].forEach(function (name) {
      var sdb = db.getSiblingDB(name);
      sdb.getCollectionNames().sort().forEach(function (coll) {
        if (coll === "${probeCollection}") { return; }
        out.push("UNIFICOUNT " + name + "." + coll + "=" + sdb.getCollection(coll).countDocuments({}));
      });
    });
    print(out.join("\n"));
  '';

  # Unauthenticated: only ever used against the throwaway legacy-copy instance,
  # which never had access control.
  countsJs = ''
    (function () {
      ${countsBody}
    })()
  '';

  # The same counts against the live container, authenticated as the
  # application role — which also proves the grant set is sufficient to read
  # everything that was restored.
  appCountsJs = ''
    (function () {
      try {
        db.getSiblingDB("admin").auth(APP_USER, APP_PASS);
      } catch (e) {
        print("application authentication failed: " + e.message);
        quit(11);
      }
      ${countsBody}
    })()
  '';

  # ---------------------------------------------------------------------------
  # system.properties renderer (shared by the setup unit and the migration)
  # ---------------------------------------------------------------------------
  #
  # Only ever called once the migration marker exists. Deploying this module
  # therefore mutates NO persistent UniFi state: until the operator runs the
  # migration, system.properties still selects the embedded database and
  # rolling back is a pure generation switch. In the first attempt this file was
  # rewritten at deploy time, so a generation rollback silently left the
  # embedded controller pointing at the empty external database.
  renderSystemProperties = pkgs.writeShellApplication {
    name = "unifi-mongodb-render-system-properties";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep];
    text = ''
      ${assertAlnum}

      app_user="$(cat ${lib.escapeShellArg mongoAppUser})"
      app_pass="$(cat ${lib.escapeShellArg mongoAppPass})"
      assert_alnum "app username" "$app_user"
      assert_alnum "app password" "$app_pass"

      install -d -o unifi -g unifi -m 0700 ${lib.escapeShellArg (dirOf systemProperties)}

      # Preserve the pre-migration file exactly once. This is the rollback
      # artefact; never overwrite it with an already-migrated copy.
      if [ -f ${lib.escapeShellArg systemProperties} ] && [ ! -f ${lib.escapeShellArg systemPropertiesBackup} ]; then
        install -m 0600 -o unifi -g unifi \
          ${lib.escapeShellArg systemProperties} ${lib.escapeShellArg systemPropertiesBackup}
        echo "unifi-mongodb: saved pre-migration system.properties to ${systemPropertiesBackup}"
      fi

      # Preserve every line UniFi or the operator owns; replace only the four
      # keys that select the database backend.
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

  # ---------------------------------------------------------------------------
  # Setup unit: wait for the real mongod, ensure the role, render if migrated
  # ---------------------------------------------------------------------------
  mongoSetup = pkgs.writeShellApplication {
    name = "unifi-mongodb-setup";
    runtimeInputs = [pkgs.coreutils config.virtualisation.podman.package];
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

      ${redactFn}
      ${mongoshHelpers}

      run_mongosh() { # $1 = root|app, $2 = JS; sets MONGOSH_OUT, returns mongosh's status
        local rc=0
        MONGOSH_OUT="$(mongosh_script "$1" "$2" \
          | ${podmanBin} exec -i ${containerName} mongosh --quiet --norc 2>&1)" || rc=$?
        return "$rc"
      }

      # 1. Readiness. All three conditions must hold in the SAME iteration.
      ready=0
      detail="mongod never answered"
      for _ in $(seq 1 ${toString mcfg.startupTimeoutSeconds}); do
        # The published loopback socket is the exact one UniFi dials. Podman
        # DNATs it to the container's bridge address, which the image's
        # initialisation mongod — bound to the container's own loopback —
        # cannot answer, so this alone already excludes the transient server.
        if ! timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${toString mcfg.port}' 2>/dev/null; then
          detail="published port 127.0.0.1:${toString mcfg.port} is not accepting connections"
          sleep 1
          continue
        fi

        rc=0
        run_mongosh root ${lib.escapeShellArg readinessJs} || rc=$?
        case "$rc" in
          0)
            ready=1
            break
            ;;
          10) detail="mongod is still the image's initialisation server (access control not enforced)" ;;
          11) detail="root authentication failed against the running mongod" ;;
          12) detail="ping failed after successful root authentication" ;;
          *) detail="mongosh exited $rc: $(redact "$MONGOSH_OUT")" ;;
        esac
        sleep 1
      done

      if [ "$ready" -ne 1 ]; then
        echo "unifi-mongodb: authenticated mongod did not become ready within ${toString mcfg.startupTimeoutSeconds}s" >&2
        echo "unifi-mongodb: last state: $detail" >&2
        exit 1
      fi

      # 2. Application role.
      rc=0
      run_mongosh root ${lib.escapeShellArg ensureRoleJs} || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "unifi-mongodb: failed to ensure the UniFi application role (mongosh exited $rc)" >&2
        echo "unifi-mongodb: $(redact "$MONGOSH_OUT")" >&2
        exit 1
      fi

      # 3. system.properties — only once the operator's migration has completed
      #    and been verified. Before that this module leaves UniFi's persistent
      #    configuration untouched, so a rollback is a pure generation switch.
      if [ -e ${lib.escapeShellArg migrationMarker} ]; then
        ${lib.getExe renderSystemProperties}
      else
        echo "unifi-mongodb: role provisioned; system.properties left untouched until the migration completes."
        echo "unifi-mongodb: run 'systemctl start unifi-mongodb-migrate' (docs/wiki/services/unifi-controller.md)."
      fi
    '';
  };

  # ---------------------------------------------------------------------------
  # Migration: legacy embedded dbpath -> external container, contents-first
  # ---------------------------------------------------------------------------
  #
  # Never started automatically. Copies the frozen embedded dbpath, serves the
  # COPY with a throwaway mongod from the same pinned image, dumps it, restores
  # it into the container under the SAME namespaces, and verifies every
  # collection count as the application role before recording the marker.
  #
  # ${legacyDbPath} itself is only ever read: it is copied, never mounted, so it
  # stays byte-frozen as the rollback.
  migrateScript = pkgs.writeShellApplication {
    name = "unifi-mongodb-migrate";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.diffutils pkgs.systemd config.virtualisation.podman.package];
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

      ${redactFn}
      ${mongoshHelpers}

      force="''${UNIFI_MIGRATE_FORCE:-0}"

      fail() {
        echo "unifi-mongodb-migrate: $*" >&2
        exit 1
      }

      cleanup_source() {
        ${podmanBin} rm -f ${sourceContainer} >/dev/null 2>&1 || true
      }
      trap cleanup_source EXIT

      target_counts() {
        mongosh_script app ${lib.escapeShellArg appCountsJs} \
          | ${podmanBin} exec -i ${containerName} mongosh --quiet --norc 2>&1 \
          | parse_counts
      }

      # --- preconditions -----------------------------------------------------
      if [ -e ${lib.escapeShellArg migrationMarker} ] && [ "$force" != "1" ]; then
        fail "migration marker already present (${migrationMarker}); refusing to restore twice."
      fi
      if systemctl is-active --quiet unifi.service; then
        fail "unifi.service is running. Stop it first — the legacy dbpath must be quiescent."
      fi
      if ! systemctl is-active --quiet ${containerUnit}; then
        fail "${containerUnit} is not running."
      fi
      if [ ! -d ${lib.escapeShellArg legacyDbPath} ] || [ -z "$(ls -A ${lib.escapeShellArg legacyDbPath} 2>/dev/null)" ]; then
        fail "legacy embedded dbpath ${legacyDbPath} is missing or empty; nothing to migrate."
      fi

      # Refuse if the target already holds UniFi documents. The deep probe's own
      # collection is excluded by countsJs, so a probe run does not trip this.
      existing="$(target_counts || true)"
      if printf '%s\n' "$existing" | grep -qE '=[1-9][0-9]*$'; then
        [ "$force" = "1" ] || fail "the external database already contains UniFi documents; refusing to restore over it."
      fi

      legacy_kib="$(du -sk ${lib.escapeShellArg legacyDbPath} | cut -f1)"
      free_kib="$(df -Pk ${lib.escapeShellArg mcfg.dataDir} | awk 'NR==2 {print $4}')"
      if [ "$free_kib" -lt "$((legacy_kib * 3))" ]; then
        fail "need ~3x the legacy dbpath ($((legacy_kib / 1024)) MiB) free on ${mcfg.dataDir}; have $((free_kib / 1024)) MiB."
      fi

      # --- 1. copy the frozen legacy dbpath ----------------------------------
      echo "unifi-mongodb-migrate: copying the legacy dbpath ($((legacy_kib / 1024)) MiB) to ${legacyCopy}"
      rm -rf ${lib.escapeShellArg legacyCopy}
      install -d -o unifi-mongodb -g unifi-mongodb -m 0750 ${lib.escapeShellArg migrationDir}
      install -d -o unifi-mongodb -g unifi-mongodb -m 0750 ${lib.escapeShellArg dumpDir}
      cp -a ${lib.escapeShellArg legacyDbPath} ${lib.escapeShellArg legacyCopy}
      chown -R unifi-mongodb:unifi-mongodb ${lib.escapeShellArg legacyCopy}

      # --- 2. serve the COPY with a throwaway mongod -------------------------
      # Same pinned image, no published ports, --network=none. The copied dbpath
      # is non-empty, so the image's initdb phase — and its temporary
      # auth-disabled mongod — never runs here at all, which is why a plain ping
      # is the correct readiness test for THIS instance and not for the real one.
      cleanup_source
      ${podmanBin} run -d --name ${sourceContainer} \
        --network=none \
        --user=${toString mcfg.uid}:${toString mcfg.gid} \
        ${lib.concatStringsSep " " config.homelab.podman.hardenOptions} \
        -v ${lib.escapeShellArg legacyCopy}:/data/db:rw \
        -v ${lib.escapeShellArg dumpDir}:/dump:rw \
        ${lib.escapeShellArg mongodbImage} \
        mongod --bind_ip 127.0.0.1 >/dev/null

      ready=0
      for _ in $(seq 1 ${toString mcfg.startupTimeoutSeconds}); do
        if ${podmanBin} exec ${sourceContainer} \
             mongosh --quiet --norc --eval 'quit(db.adminCommand({ping:1}).ok ? 0 : 1)' >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 1
      done
      [ "$ready" -eq 1 ] || fail "the legacy-copy mongod did not start; see 'podman logs ${sourceContainer}'."

      # --- 3. record source counts, then dump --------------------------------
      # No credentials are involved on this instance, so --eval is safe here.
      ${podmanBin} exec ${sourceContainer} mongosh --quiet --norc \
        --eval ${lib.escapeShellArg countsJs} | parse_counts > ${lib.escapeShellArg sourceCounts}
      [ -s ${lib.escapeShellArg sourceCounts} ] || fail "the legacy copy reported no UniFi collections; aborting."
      echo "unifi-mongodb-migrate: source holds $(wc -l < ${lib.escapeShellArg sourceCounts}) collections"

      rm -f ${lib.escapeShellArg dumpArchive}
      ${podmanBin} exec ${sourceContainer} mongodump --archive=/dump/unifi.archive --quiet
      [ -s ${lib.escapeShellArg dumpArchive} ] || fail "mongodump produced no archive."
      echo "unifi-mongodb-migrate: dumped $(du -h ${lib.escapeShellArg dumpArchive} | cut -f1) to ${dumpArchive}"
      cleanup_source

      # --- 4. restore into the external container ----------------------------
      # The archive streams in on stdin. Credentials never reach argv: the
      # wrapper builds a mongorestore --config file INSIDE the container from
      # the root secret the container already has bind-mounted, and that file
      # carries the whole mongodb:// URI, username and password both.
      echo "unifi-mongodb-migrate: restoring into ${containerName}"
      ${podmanBin} exec -i ${containerName} sh -c '
        set -e
        umask 077
        cfg="$(mktemp)"
        trap "rm -f \"$cfg\"" EXIT
        printf "uri: mongodb://%s:%s@127.0.0.1:27017/?authSource=admin\n" \
          "$(cat /run/secrets/unifi-mongodb-root-username)" \
          "$(cat /run/secrets/unifi-mongodb-root-password)" > "$cfg"
        mongorestore --config "$cfg" --quiet --archive \
          ${lib.concatMapStringsSep " " (db: ''--nsInclude "${db}.*"'') dataDatabases}
      ' < ${lib.escapeShellArg dumpArchive}

      # --- 5. verify as the APPLICATION role ---------------------------------
      # Reading the restored data back with the app credential proves the grant
      # set is sufficient, not merely that root could write. Counts, not the
      # controller uuid: uuid lives in system.properties on disk and survives
      # regardless, so it proves nothing at all about the database.
      restored="$(target_counts)"
      [ -n "$restored" ] || fail "could not read the restored data back as the application role."
      if ! printf '%s\n' "$restored" | diff -u ${lib.escapeShellArg sourceCounts} - > "$TMPDIR/counts.diff" 2>&1; then
        echo "unifi-mongodb-migrate: RESTORE MISMATCH (source vs target):" >&2
        head -50 "$TMPDIR/counts.diff" >&2
        fail "collection counts differ; the marker was NOT written and UniFi stays gated off."
      fi
      echo "unifi-mongodb-migrate: verified $(wc -l < ${lib.escapeShellArg sourceCounts}) collections, counts identical"

      # --- 6. record the migration and point UniFi at the container ----------
      touch ${lib.escapeShellArg migrationMarker}
      ${lib.getExe renderSystemProperties}
      echo "unifi-mongodb-migrate: done. Now run:  systemctl start unifi  &&  unifi-mongodb-verify"
    '';
  };

  # ---------------------------------------------------------------------------
  # Verification (acceptance checks, runnable any time)
  # ---------------------------------------------------------------------------
  verifyScript = pkgs.writeShellApplication {
    name = "unifi-mongodb-verify";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.diffutils pkgs.curl pkgs.systemd pkgs.iproute2 config.virtualisation.podman.package];
    text = ''
      ${assertAlnum}

      root_user="$(cat ${lib.escapeShellArg mongoRootUser})"
      root_pass="$(cat ${lib.escapeShellArg mongoRootPass})"
      app_user="$(cat ${lib.escapeShellArg mongoAppUser})"
      app_pass="$(cat ${lib.escapeShellArg mongoAppPass})"

      ${redactFn}
      ${mongoshHelpers}

      fails=0
      check() { # $1 = label, $2 = 0 (pass) or non-zero (fail)
        if [ "$2" -eq 0 ]; then
          echo "  PASS  $1"
        else
          echo "  FAIL  $1"
          fails=$((fails + 1))
        fi
      }

      echo "unifi-mongodb-verify:"

      rc=0
      systemctl is-active --quiet ${containerUnit} || rc=1
      check "${containerUnit} is active" "$rc"

      rc=0
      ${podmanBin} inspect --format '{{.ImageName}}' ${containerName} 2>/dev/null \
        | grep -qF ${lib.escapeShellArg mongodbImage} || rc=1
      check "container runs the digest-pinned image (MongoDB ${mongodbVersion})" "$rc"

      # Loopback only: the published socket must exist on 127.0.0.1 and nowhere
      # else — not on the LAN addresses and not on the tailnet address.
      rc=0
      if ss -HltnA inet 2>/dev/null | awk '{print $4}' \
           | grep -E ':${toString mcfg.port}$' | grep -qv '^127\.0\.0\.1:'; then
        rc=1
      fi
      check "MongoDB published on loopback only (nothing else listens on ${toString mcfg.port})" "$rc"

      rc=0
      probe_out="$(mongosh_script root ${lib.escapeShellArg readinessJs} \
        | ${podmanBin} exec -i ${containerName} mongosh --quiet --norc 2>&1)" || rc=1
      check "access control enforced and the root credential authenticates" "$rc"
      [ "$rc" -eq 0 ] || echo "        $(redact "$probe_out")"

      if [ -f ${lib.escapeShellArg sourceCounts} ]; then
        rc=0
        restored="$(mongosh_script app ${lib.escapeShellArg appCountsJs} \
          | ${podmanBin} exec -i ${containerName} mongosh --quiet --norc 2>&1 | parse_counts)" || rc=1
        if [ "$rc" -eq 0 ]; then
          printf '%s\n' "$restored" | diff -q ${lib.escapeShellArg sourceCounts} - >/dev/null 2>&1 || rc=1
        fi
        check "every migrated collection count still matches the pre-migration source" "$rc"
      fi

      rc=0
      [ -e ${lib.escapeShellArg migrationMarker} ] || rc=1
      check "migration marker present" "$rc"

      rc=0
      grep -q '^db\.mongo\.local=false$' ${lib.escapeShellArg systemProperties} 2>/dev/null || rc=1
      grep -q '^unifi\.db\.name=${mcfg.databaseName}$' ${lib.escapeShellArg systemProperties} 2>/dev/null || rc=1
      check "system.properties selects the external database" "$rc"

      rc=0
      [ -f ${lib.escapeShellArg systemPropertiesBackup} ] || rc=1
      check "pre-migration system.properties preserved for rollback" "$rc"

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

  # ---------------------------------------------------------------------------
  # Rollback (executable, verified)
  # ---------------------------------------------------------------------------
  #
  # The first attempt's documented rollback was incomplete: it switched
  # generations but never mentioned system.properties, which
  # unifi-mongodb-setup had rewritten in the PERSISTENT data dir. The restored
  # embedded controller would have come up against the EMPTY external database.
  # Here the data-plane revert happens FIRST and is verified, and only then is
  # the generation switched.
  rollbackScript = pkgs.writeShellApplication {
    name = "unifi-mongodb-rollback";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.systemd pkgs.nix pkgs.curl];
    text = ''
      generation=""
      confirmed=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --generation)
            generation="''${2:?--generation needs a number}"
            shift 2
            ;;
          --yes)
            confirmed=1
            shift
            ;;
          *)
            echo "usage: unifi-mongodb-rollback [--generation N] --yes" >&2
            exit 2
            ;;
        esac
      done

      profile=/nix/var/nix/profiles/system
      current="$(readlink "$profile" | sed 's/^system-//; s/-link$//')"
      if [ -z "$generation" ]; then
        generation="$(nix-env --list-generations -p "$profile" \
          | awk '{print $1}' | grep -v "^$current\$" | tail -1)"
      fi
      [ -n "$generation" ] || {
        echo "could not determine a previous generation; pass --generation N" >&2
        exit 1
      }
      [ -e "$profile-$generation-link" ] || {
        echo "generation $generation does not exist" >&2
        exit 1
      }

      echo "unifi-mongodb-rollback:"
      echo "  current generation : $current"
      echo "  rolling back to    : $generation"
      echo "  restoring          : ${systemProperties}"
      echo "                       from ${systemPropertiesBackup}"
      echo "  NOT touched        : ${legacyDbPath} (frozen embedded database)"
      echo "                       ${mcfg.dataDir} (external dbpath + migration copy)"
      if [ "$confirmed" -ne 1 ]; then
        echo "Re-run with --yes to execute." >&2
        exit 2
      fi

      # 1. Stop the controller before touching its configuration.
      systemctl stop unifi.service || true
      if systemctl is-active --quiet unifi.service; then
        echo "unifi.service would not stop" >&2
        exit 1
      fi

      # 2. Revert system.properties. Exact restore when the pre-migration copy
      #    exists; otherwise strip the four external-database keys, which
      #    returns UniFi to its embedded default (db.mongo.local defaults true).
      if [ -f ${lib.escapeShellArg systemPropertiesBackup} ]; then
        install -m 0600 -o unifi -g unifi \
          ${lib.escapeShellArg systemPropertiesBackup} ${lib.escapeShellArg systemProperties}
        echo "  restored system.properties from the pre-migration copy"
      elif [ -f ${lib.escapeShellArg systemProperties} ]; then
        tmp="$(mktemp ${lib.escapeShellArg systemProperties}.XXXXXX)"
        grep -vE '^(db\.mongo\.local|db\.mongo\.uri|statdb\.mongo\.uri|unifi\.db\.name)=' \
          ${lib.escapeShellArg systemProperties} > "$tmp" || true
        chown unifi:unifi "$tmp"
        chmod 0600 "$tmp"
        mv "$tmp" ${lib.escapeShellArg systemProperties}
        echo "  no pre-migration copy; stripped the external-database keys instead"
      fi
      if grep -qE '^(db\.mongo\.local=false|db\.mongo\.uri=|statdb\.mongo\.uri=)' \
           ${lib.escapeShellArg systemProperties} 2>/dev/null; then
        echo "external-database keys survived the revert; refusing to switch generations" >&2
        exit 1
      fi
      echo "  verified: no external-database keys remain in system.properties"

      # 3. Drop the marker so a later re-attempt re-gates properly.
      rm -f ${lib.escapeShellArg migrationMarker}

      # 4. Only now switch back. The old generation is already in the store, so
      #    this needs no rebuild and no network.
      nix-env -p "$profile" --switch-generation "$generation"
      "$profile/bin/switch-to-configuration" switch

      # 5. Verify the embedded controller actually came back.
      ok=1
      for _ in $(seq 1 60); do
        if curl -ksf --max-time 5 https://127.0.0.1:8443/status | grep -q '"up":true'; then
          ok=0
          break
        fi
        sleep 5
      done
      if [ "$ok" -ne 0 ]; then
        echo "unifi-mongodb-rollback: controller did not report up:true within 5 minutes" >&2
        echo "  check: systemctl status unifi; tail /var/log/unifi/server.log" >&2
        exit 1
      fi
      echo "unifi-mongodb-rollback: controller is back up on generation $generation"
    '';
  };

  # Refuse to start UniFi against the external database while the legacy
  # embedded dbpath still holds data and the operator has not run the
  # migration. Starting anyway would bring the controller up EMPTY — an
  # unadopted, factory-looking controller — which is far worse and far less
  # reversible than staying down and paging the Kuma monitor.
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
      echo "Run the migration — it copies the frozen embedded database into the" >&2
      echo "container and verifies every collection count before recording it:" >&2
      echo "  systemctl start unifi-mongodb-migrate" >&2
      echo "See docs/wiki/services/unifi-controller.md." >&2
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
          memory and any local tooling keep working; it is free once the
          embedded instance is gone.
        '';
      };

      databaseName = lib.mkOption {
        type = lib.types.str;
        default = "ace";
        description = ''
          Primary UniFi database name (`unifi.db.name`). The controller also
          uses <name>_stat, <name>_audit and <name>_restore.

          `ace` is BOTH UniFi's own default and the name the embedded instance
          already uses, so the migration restores every namespace unchanged —
          no cross-database rename and no `--nsFrom` pattern to get wrong.
          Do not change this to `unifi` for cosmetics: that would turn a
          same-name restore into a rename of roughly a hundred collections.
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
        default = 180;
        description = ''
          How long the setup unit waits for the FINAL, authenticated mongod.
          Must comfortably exceed the official image's first-boot initialisation
          (temporary mongod, root user creation, shutdown, restart), which the
          readiness gate deliberately refuses to accept as ready.
        '';
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

    # Operator tooling for the cutover window. The migration itself is a
    # systemd unit (journal capture + secret access + mount ordering); these two
    # are the ones an operator runs by hand under pressure.
    environment.systemPackages = [verifyScript rollbackScript];

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
      # Application credential: only ever read by root-run host units (the setup
      # unit, the migration, the verifier and the deep probe). The container
      # never sees it.
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
                "UNIFI_MONGO_COLLECTION=${probeCollection}"
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
          {
            name = "UniFi MongoDB migration failure";
            unit = "unifi-mongodb-migrate.service";
            pattern = "(?i)(RESTORE MISMATCH|collection counts differ|refusing to restore)";
            severity = "critical";
            summary = "The UniFi database migration aborted; UniFi remains gated off and the embedded database is untouched";
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
      # relying on the entrypoint inferring it from the root credential, and the
      # readiness gate keys off it being genuinely enforced.
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
        # ExecCondition runs), so the role is provisioned and ready for the
        # operator's migration even while UniFi stays down.
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
          # The image's first-boot initialisation (temporary mongod, root user,
          # shutdown, restart) must fit inside the unit's own timeout, or
          # systemd kills the unit while the gate is correctly still waiting.
          TimeoutStartSec = mcfg.startupTimeoutSeconds + 60;
          # doc2 default (#257): blank tmpfs over /mnt, bind back only the
          # controller state dir this unit actually writes into.
          TemporaryFileSystem = "/mnt";
          BindPaths = [cfg.dataDir];
        };
      };

      # Explicit, operator-run data migration. Deliberately not wantedBy any
      # target: it copies, dumps, restores and verifies, then records the
      # marker. Everything it needs ships in the pinned image.
      unifi-mongodb-migrate = {
        description = "Migrate the embedded UniFi database into the external MongoDB container";
        after = [containerUnit "unifi-mongodb-setup.service"];
        requires = [containerUnit "unifi-mongodb-setup.service"];
        unitConfig.RequiresMountsFor = [cfg.dataDir mcfg.dataDir];
        serviceConfig = {
          Type = "oneshot";
          NoNewPrivileges = true;
          ExecStart = lib.getExe migrateScript;
          # A first migration copies and restores a few hundred MiB.
          TimeoutStartSec = "2h";
          PrivateTmp = true;
          TemporaryFileSystem = "/mnt";
          BindPaths = [cfg.dataDir mcfg.dataDir];
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
