# mk-pg-container.nix — Creates an isolated PostgreSQL instance in a NixOS container.
#
# Returns an attrset with:
#   containerConfig — value for containers.<name>
#   dbUri           — connection string for the service
#   hostAddress     — host-side veth IP
#   localAddress    — container-side veth IP
#
# IP addressing: hostNum N → host 192.168.100.(N*2), container 192.168.100.(N*2+1)
# Each service gets a unique hostNum to avoid collisions.
{
  pkgs,
  name,
  hostNum,
  dataDir,
  pgPackage ? pkgs.postgresql_16,
  extraPgConfig ? {},
}: let
  hostAddress = "192.168.100.${toString (hostNum * 2)}";
  localAddress = "192.168.100.${toString (hostNum * 2 + 1)}";
in {
  inherit hostAddress localAddress;
  dbHost = localAddress;
  dbPort = 5432;
  dbUri = "postgresql://${name}@${localAddress}:5432/${name}";

  containerConfig = {
    autoStart = true;
    privateNetwork = true;
    inherit hostAddress localAddress;

    bindMounts."/var/lib/postgresql" = {
      hostPath = "${dataDir}/postgres";
      isReadWrite = true;
    };

    config = {lib, ...}: {
      services.postgresql =
        {
          enable = true;
          package = pgPackage;
          enableTCPIP = true;
          ensureDatabases = [name];
          ensureUsers = [
            {
              inherit name;
              ensureDBOwnership = true;
            }
          ];
          authentication = lib.mkForce ''
            local all all peer
            host all all ${hostAddress}/32 trust
          '';
        }
        // extraPgConfig;

      networking.firewall.allowedTCPPorts = [5432];

      # NixOS containers need this or DNS resolution fails (nixpkgs #162686)
      networking.useHostResolvConf = lib.mkForce false;
      services.resolved.enable = true;

      system.stateVersion = "25.05";
    };
  };
}
