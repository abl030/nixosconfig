{
  self,
  lib,
  pkgs,
}: let
  # The MongoDB package is a binary-only 8.0 series contract. Exercise
  # both the fail-closed updater fixture and the evaluated native service
  # boundary; the latter is independent of the package's own source text.
  mongodb80CandidateVersion = let
    parts = lib.splitString "." self.nixosConfigurations.doc2.config.services.mongodb.package.version;
  in "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}.${toString (builtins.fromJSON (builtins.elemAt parts 2) + 1)}";

  mongodb80FixtureArchive =
    pkgs.runCommand "mongodb80-updater-fixture-archive" {
      nativeBuildInputs = [pkgs.gnutar];
    } ''
      set -euo pipefail
      root="$TMPDIR/mongodb-linux-x86_64-ubuntu2404-${mongodb80CandidateVersion}"
      mkdir -p "$root/bin"
      touch "$root/bin/mongod" "$root/bin/mongos"
      tar -czf "$out" -C "$TMPDIR" "mongodb-linux-x86_64-ubuntu2404-${mongodb80CandidateVersion}"
    '';

  mongodb80FixtureArchiveMissingMongos =
    pkgs.runCommand "mongodb80-updater-fixture-archive-missing-mongos" {
      nativeBuildInputs = [pkgs.gnutar];
    } ''
      set -euo pipefail
      root="$TMPDIR/mongodb-linux-x86_64-ubuntu2404-${mongodb80CandidateVersion}"
      mkdir -p "$root/bin"
      touch "$root/bin/mongod"
      tar -czf "$out" -C "$TMPDIR" "mongodb-linux-x86_64-ubuntu2404-${mongodb80CandidateVersion}"
    '';

  mongodb80UpdaterCheck =
    pkgs.runCommand "mongodb80-updater-package" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnutar pkgs.jq pkgs.python3];
    } ''
      set -euo pipefail
      MONGODB80_PACKAGE_SOURCE=${../pkgs/mongodb80.nix} \
      MONGODB80_UPDATER_SOURCE=${../../scripts/update_mongodb80.sh} \
      MONGODB80_TEST_COMPLETE_ARCHIVE=${mongodb80FixtureArchive} \
      MONGODB80_TEST_MISSING_MONGOS_ARCHIVE=${mongodb80FixtureArchiveMissingMongos} \
      MONGODB80_TEST_CANDIDATE_VERSION=${mongodb80CandidateVersion} \
        ${pkgs.python3}/bin/python3 ${./test_mongodb80_update.py}
      ROLLING_UPDATE_SOURCE=${../../scripts/rolling_flake_update.sh} \
        ${pkgs.python3}/bin/python3 ${./test_rolling_mongodb80_transaction.py}
      touch "$out"
    '';

  mongodb80IntegrationCheck = let
    doc2 = self.nixosConfigurations.doc2.config;
    mongo = doc2.services.mongodb;
    mongoPackage = mongo.package;
    mongoUnit = doc2.systemd.services.mongodb.serviceConfig;
    mongoUnitArtifact = doc2.systemd.units."mongodb.service".unit;
    setupUnit = doc2.systemd.services.unifi-mongodb-setup.serviceConfig;
    verifier = lib.findFirst (p: (p.name or "") == "unifi-mongodb-verify") null doc2.environment.systemPackages;
    probePackage = import ../../modules/nixos/services/probes/check-unifi-mongodb.nix {inherit pkgs;};
    setupUnitArtifact = doc2.systemd.units."unifi-mongodb-setup.service".unit;
    unifiUnitArtifact = doc2.systemd.units."unifi.service".unit;
    unifi = doc2.services.unifi;
    probe =
      lib.findFirst
      (entry: entry.name == "UniFi MongoDB write-path")
      null
      doc2.homelab.monitoring.deepProbes;
    containerConfigured = builtins.hasAttr "unifi-mongodb" doc2.virtualisation.oci-containers.containers;
    firewallText = lib.concatStringsSep "\n" [
      doc2.networking.firewall.extraCommands
      doc2.networking.firewall.extraInputRules
    ];
  in
    assert lib.assertMsg (mongo.enable && mongo.package == pkgs.mongodb80) "doc2 must enable the explicit mongodb80 package";
    assert lib.assertMsg (lib.hasPrefix "8.0." mongo.package.version) "MongoDB package must remain on the 8.0 patch series";
    assert lib.assertMsg (mongo.package.passthru.mongodbSeries == "8.0") "MongoDB package must expose the protected 8.0 series";
    assert lib.assertMsg (mongo.package.meta.sourceProvenance
      == [
        {
          isSource = false;
          shortName = "binaryNativeCode";
        }
      ]) "MongoDB package must be binary-native provenance";
    assert lib.assertMsg (mongo.bind_ip == "127.0.0.1" && mongo.dbpath == "/mnt/virtio/unifi-mongodb/db") "MongoDB must bind localhost and use the native dbpath";
    assert lib.assertMsg (mongo.extraConfig == ("net.port: 27117\n" + "security.authorization: " + "en" + "abled\n")) "MongoDB auth/port config must be explicit";
    assert lib.assertMsg (!mongo.enableAuth) "upstream first-start auth bootstrap must stay disabled for the existing authenticated dbpath";
    assert lib.assertMsg (mongo.user == "unifi-mongodb") "MongoDB must run as its dedicated non-root user";
    assert lib.assertMsg (!containerConfigured) "the old UniFi MongoDB container must be absent";
    assert lib.assertMsg (unifi.mongodbPackage.name == "unifi-mongodb-absent") "UniFi must not receive an embedded mongod package";
    assert lib.assertMsg (mongoUnit.Restart == "on-failure" && mongoUnit.RestartSec == "5s") "native MongoDB must restart on failure";
    assert lib.assertMsg (mongoUnit.ProtectSystem == "strict" && mongoUnit.ProtectHome && mongoUnit.PrivateDevices && mongoUnit.PrivateTmp && mongoUnit.BindLogSockets) "native MongoDB sandbox is incomplete";
    assert lib.assertMsg (mongoUnit.NoNewPrivileges && mongoUnit.CapabilityBoundingSet == "" && mongoUnit.AmbientCapabilities == "" && mongoUnit.RestrictSUIDSGID) "native MongoDB privilege boundary is incomplete";
    assert lib.assertMsg (!mongoUnit.PermissionsStartOnly && lib.hasInfix "storage.bson" doc2.systemd.services.mongodb.preStart && !(lib.hasInfix "mongod.lock" doc2.systemd.services.mongodb.preStart)) "MongoDB must reject empty state without root initialization or lock deletion";
    assert lib.assertMsg (setupUnit.CapabilityBoundingSet == ["CAP_DAC_OVERRIDE" "CAP_SETUID" "CAP_SETGID"] && setupUnit.TemporaryFileSystem == "/mnt" && setupUnit.BindReadOnlyPaths == ["/mnt/virtio/unifi"]) "setup needs bounded privilege-drop capabilities and isolated controller storage";
    assert lib.assertMsg (mongoUnit.ReadWritePaths == ["/mnt/virtio/unifi-mongodb/db"]) "native MongoDB writable path is broader or narrower than its db root";
    assert lib.assertMsg ((setupUnit.Environment or []) == [] && setupUnit.ReadWritePaths == ["/mnt/virtio/unifi/data"]) "MongoDB setup must not carry credentials or broad write access";
    assert lib.assertMsg (probe != null) "native MongoDB must retain a deep write-path probe";
    assert lib.assertMsg (probe.serviceConfig.User == "unifi-mongodb-probe" && probe.serviceConfig.Group == "unifi-mongodb-probe") "deep MongoDB probe must use its dedicated user";
    assert lib.assertMsg (probe.serviceConfig.CapabilityBoundingSet == "" && probe.serviceConfig.PrivateDevices && probe.serviceConfig.PrivateTmp && probe.serviceConfig.ProtectSystem == "strict") "deep MongoDB probe sandbox is incomplete";
    assert lib.assertMsg (doc2.sops.secrets."unifi-mongodb/app-password".owner == "unifi-mongodb-probe" && doc2.sops.secrets."unifi-mongodb/app-password".group == "unifi-mongodb-probe") "application credential must be scoped to the probe user";
    assert lib.assertMsg (lib.all (entry: !(lib.hasPrefix "UNIFI_MONGO_PASSWORD=" entry)) probe.serviceConfig.Environment) "deep probe must use a password file, not a password environment value";
    assert lib.assertMsg (!(builtins.elem 27117 doc2.networking.firewall.allowedTCPPorts) && !(builtins.elem 27117 doc2.networking.firewall.allowedUDPPorts) && !(lib.hasInfix "27117" firewallText)) "MongoDB port must not be opened in the firewall";
      pkgs.runCommand "mongodb80-native-integration" {
        nativeBuildInputs = [pkgs.gnugrep];
      } ''
        set -euo pipefail
        test -x ${mongoPackage}/bin/mongod
        test -x ${mongoPackage}/bin/mongos
        test -x ${verifier}/bin/unifi-mongodb-verify
        test -x ${probePackage}/bin/check-unifi-mongodb
        test ! -e ${unifi.mongodbPackage}/bin/mongod
        ${pkgs.gnugrep}/bin/grep -F 'ExecStart=${mongoPackage}/bin/mongod' ${mongoUnitArtifact}/mongodb.service >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'User=unifi-mongodb' ${mongoUnitArtifact}/mongodb.service >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'Restart=on-failure' ${mongoUnitArtifact}/mongodb.service >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'NoNewPrivileges=true' ${mongoUnitArtifact}/mongodb.service >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'ProtectSystem=strict' ${mongoUnitArtifact}/mongodb.service >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'BindLogSockets=true' ${mongoUnitArtifact}/mongodb.service >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'ReadWritePaths=/mnt/virtio/unifi-mongodb' ${mongoUnitArtifact}/mongodb.service >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'ExecCondition=' ${unifiUnitArtifact}/unifi.service >/dev/null
        setup_script=$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-unifi-mongodb-setup/bin/unifi-mongodb-setup' ${setupUnitArtifact}/unifi-mongodb-setup.service)
        test -n "$setup_script"
        renderer_script=$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-unifi-mongodb-render-system-properties/bin/unifi-mongodb-render-system-properties' "$setup_script")
        test -n "$renderer_script"
        ${pkgs.gnugrep}/bin/grep -F 'db.mongo.local=false' "$renderer_script" >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'unifi.db.name=ace' "$renderer_script" >/dev/null
        ${pkgs.gnugrep}/bin/grep -F 'db.mongo.uri=mongodb://$app_user:' "$renderer_script" >/dev/null
        touch "$out"
      '';

  # Exercise the exact UniFi package's bundled Logback jars and prove
  # the generated file is selected by the realized JVM command. The
  # harness writes only fake credentials to an isolated temporary log
  # directory; it never reads the controller's persistent data.
  unifiLogbackRedactionCheck = let
    doc2 = self.nixosConfigurations.doc2.config;
    unifi = doc2.services.unifi;
    service = doc2.systemd.services.unifi.serviceConfig;
    logbackPrefix = "-Dlogback.configurationFile=";
    logbackOption = lib.findFirst (option: lib.hasPrefix logbackPrefix option) null unifi.extraJvmOptions;
    logbackConfig = assert lib.assertMsg (logbackOption != null) "UniFi must select the Nix-managed redacted Logback configuration";
      builtins.substring
      (builtins.stringLength logbackPrefix)
      (builtins.stringLength logbackOption - builtins.stringLength logbackPrefix)
      logbackOption;
  in
    assert lib.assertMsg (unifi.extraJvmOptions != []) "UniFi Logback redaction must not be disabled by an empty JVM option list";
    assert lib.assertMsg (lib.hasInfix "-Dlogback.configurationFile=" service.ExecStart) "realized unifi.service must pass a Logback configuration to Java";
      pkgs.runCommand "unifi-logback-redaction" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euo pipefail
        test -r ${lib.escapeShellArg logbackConfig}
        test -r ${lib.escapeShellArg "${unifi.unifiPackage}/lib/ace.jar"}
        test -x ${lib.escapeShellArg "${unifi.jrePackage}/bin/java"}
        ${pkgs.python3}/bin/python3 ${./test_unifi_logback_redaction.py} \
          ${lib.escapeShellArg (toString unifi.unifiPackage)} \
          ${lib.escapeShellArg (toString unifi.jrePackage)} \
          ${lib.escapeShellArg logbackConfig}
        touch "$out"
      '';
in {
  inherit
    mongodb80UpdaterCheck
    mongodb80IntegrationCheck
    unifiLogbackRedactionCheck
    ;
}
