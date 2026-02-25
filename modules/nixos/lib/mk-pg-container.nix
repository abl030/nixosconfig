# mk-pg-container.nix — Creates an isolated PostgreSQL instance in a NixOS container.
#
# Returns an attrset with:
#   containerConfig — value for containers.<name>
#   dbUri           — connection string for the service
#   dbHost          — container-side IP (for TCP connections)
#   dbPort          — 5432
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
  extensions ? (_ps: []),
  pgSettings ? {},
  postStartSQL ? null,
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
      isReadOnly = false;
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
      };

      systemd.services.postgresql-setup.serviceConfig.ExecStartPost = lib.mkIf (postStartSQL != null) [
        ''${lib.getExe' pgPackage "psql"} -d "${name}" -f "${pkgs.writeText "${name}-pg-init.sql" postStartSQL}"''
      ];

      networking.firewall.allowedTCPPorts = [5432];

      # NixOS containers need this or DNS resolution fails (nixpkgs #162686)
      networking.useHostResolvConf = lib.mkForce false;
      services.resolved.enable = true;

      system.stateVersion = "25.05";
    };
  };
}
