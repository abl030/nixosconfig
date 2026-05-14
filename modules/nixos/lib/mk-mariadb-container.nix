# mk-mariadb-container.nix — Creates an isolated MariaDB instance in a NixOS container.
#
# Returns an attrset with:
#   containerConfig — value for containers.<name>
#   dbHost          — container-side IP (for TCP connections)
#   dbPort          — 3306
#   hostAddress     — host-side veth IP
#   localAddress    — container-side veth IP
#
# IP addressing matches mk-pg-container: hostNum N → host 192.168.100.(N*2),
# container 192.168.100.(N*2+1). Each service gets a unique hostNum.
#
# AUTH MODEL:
# TCP access is for the service user only and only from the host-side veth
# address. Do not grant '%' or TCP root access. Local socket access inside the
# container remains the ops backdoor via:
#   sudo machinectl shell <name>-db
# then use the local MariaDB client as the mysql user.
{
  pkgs,
  name,
  hostNum,
  dataDir,
  passwordFile, # host-side path to dotenv containing passwordVariable
  mariadbPackage ? pkgs.mariadb_1011,
  passwordVariable ? "MYSQL_PASSWORD",
  database ? name,
  user ? name,
  mysqlSettings ? {},
  postStartSQL ? null,
}: let
  hostAddress = "192.168.100.${toString (hostNum * 2)}";
  localAddress = "192.168.100.${toString (hostNum * 2 + 1)}";

  dbpassPath = "/run/secrets/mariadb.env";
in {
  inherit hostAddress localAddress;
  dbHost = localAddress;
  dbPort = 3306;

  containerConfig = {
    autoStart = true;
    privateNetwork = true;
    inherit hostAddress localAddress;

    bindMounts = {
      "/var/lib/mysql" = {
        hostPath = "${dataDir}/mysql";
        isReadOnly = false;
      };
      ${dbpassPath} = {
        hostPath = passwordFile;
        isReadOnly = true;
      };
    };

    config = {lib, ...}: {
      i18n.supportedLocales = ["en_GB.UTF-8/UTF-8" "en_AU.UTF-8/UTF-8" "en_US.UTF-8/UTF-8"];

      services.mysql = {
        enable = true;
        package = mariadbPackage;
        settings.mysqld =
          {
            bind-address = localAddress;
            port = 3306;
            character-set-server = "utf8mb4";
            collation-server = "utf8mb4_unicode_ci";
          }
          // mysqlSettings;
      };

      systemd.services.mysql.postStart = lib.mkAfter ''
        set -eu
        PASS=$(${pkgs.gnugrep}/bin/grep '^${passwordVariable}=' ${dbpassPath} | ${pkgs.coreutils}/bin/cut -d= -f2-)
        if [ -z "$PASS" ]; then
          echo "${name}-mariadb-setup: ${passwordVariable} not found in ${dbpassPath}" >&2
          exit 1
        fi
        PASS_ESC=''${PASS//\'/\'\'}

        (
          echo 'CREATE DATABASE IF NOT EXISTS `${database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'
          echo "CREATE USER IF NOT EXISTS '${user}'@'${hostAddress}' IDENTIFIED BY '$PASS_ESC';"
          echo "ALTER USER '${user}'@'${hostAddress}' IDENTIFIED BY '$PASS_ESC';"
          echo "GRANT ALL PRIVILEGES ON \`${database}\`.* TO '${user}'@'${hostAddress}';"
          ${lib.optionalString (postStartSQL != null) "cat ${pkgs.writeText "${name}-mariadb-init.sql" postStartSQL}"}
        ) | ${mariadbPackage}/bin/mysql -N
      '';

      networking.firewall.allowedTCPPorts = [3306];

      # NixOS containers need this or DNS resolution fails (nixpkgs #162686).
      networking.useHostResolvConf = lib.mkForce false;
      services.resolved.enable = true;

      system.stateVersion = "25.05";
    };
  };
}
