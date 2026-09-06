# Opt-in real-systemd fixture; never imported by the normal fleet configuration.
# The runner supplies a fresh task-only directory and uses private networking.
{
  flake,
  fixtureRoot,
}: let
  lib = flake.inputs.nixpkgs.lib;
  evaluated = flake.nixosConfigurations.doc2.extendModules {
    modules = [
      (_: {
        homelab.services.unifiController = {
          dataDir = lib.mkForce "${fixtureRoot}/mnt/unifi";
          mongodb = {
            dataDir = lib.mkForce "${fixtureRoot}/mnt/mongodb";
            port = lib.mkForce 37117;
            startupTimeoutSeconds = lib.mkForce 5;
          };
        };
        services.mongodb.pidFile = lib.mkForce "${fixtureRoot}/runtime/mongod.pid";
        sops.secrets = lib.genAttrs [
          "unifi-mongodb/root-username"
          "unifi-mongodb/root-password"
          "unifi-mongodb/app-username"
          "unifi-mongodb/app-password"
        ] (name: {path = lib.mkForce "${fixtureRoot}/secrets/${baseNameOf name}";});
      })
    ];
  };
  inherit (evaluated) config pkgs;
in
  assert builtins.match "/var/lib/mongodb80-systemd-test-[A-Za-z0-9]+" fixtureRoot != null;
    pkgs.writeText "unifi-mongodb-systemd-fixture.json" (builtins.toJSON {
      daemon = config.systemd.services.mongodb.serviceConfig;
      setup = config.systemd.services.unifi-mongodb-setup.serviceConfig;
      daemonEnvironment = config.systemd.services.mongodb.environment;
      mongosh = lib.getExe pkgs.mongosh;
      mongod = "${config.services.mongodb.package}/bin/mongod";
      bash = "${pkgs.bash}/bin/bash";
      coreutils = "${pkgs.coreutils}/bin";
      utilLinux = "${pkgs.util-linux}/bin";
    })
