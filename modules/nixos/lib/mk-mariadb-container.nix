# mk-mariadb-container.nix — Creates an isolated MariaDB instance in a NixOS container.
#
# Returns an attrset with:
#   containerConfig — value for containers.<name>
#   dbHost          — container-side IP (for TCP connections)
#   dbPort          — 3306
#   hostAddress     — host-side veth IP
#   localAddress    — container-side veth IP
#
# IP addressing matches mk-pg-container: hostNum N → host 10.20.0.(N*2),
# container 10.20.0.(N*2+1). Each service gets a unique hostNum.
# (Renumbered from 192.168.100.0/24 on 2026-06-07 — see mk-pg-container.nix / #239.)
#
# AUTH MODEL:
# TCP access is for the service user only and only from the host-side veth
# address. Do not grant '%' or TCP root access. Local socket access inside the
# container remains the ops backdoor via:
#   sudo machinectl shell <name>-db
# then use the local MariaDB client as the mysql user.
#
# `passwordFile` should be a root-only SOPS dotenv. The container copies the
# bindmounted file to a private mysql-readable runtime path before setup, so the
# host-side secret does not need to be world-readable.
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
  hostAddress = "10.20.0.${toString (hostNum * 2)}";
  localAddress = "10.20.0.${toString (hostNum * 2 + 1)}";

  dbpassPath = "/run/secrets/mariadb.env";
  dbpassRuntimePath = "/run/mariadb-${name}-dbpass.env";
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
        # Audit-friendly defaults — issue #251.
        #   server_audit plugin loaded with events scoped to CONNECT and
        #     QUERY_DDL only. Connections give us forensic "who/when"
        #     for any later schema drift; QUERY_DDL records the actual
        #     CREATE/ALTER/DROP. We deliberately do NOT enable
        #     QUERY_DML (would log every read/write, far too noisy).
        #   server_audit_excl_users = 'root@localhost,mysql@localhost'
        #     — local socket access by root is the documented ops backdoor
        #     and runs every container boot. Exclude it from the audit
        #     stream so the alert layer only sees external (TCP, host-side
        #     veth) sessions, which are the threat-model'd surface.
        #   server_audit_output_type = syslog so journald picks it up
        #     and alloy ships it to Loki under the container unit label.
        settings.mysqld =
          {
            bind-address = localAddress;
            port = 3306;
            character-set-server = "utf8mb4";
            collation-server = "utf8mb4_unicode_ci";
            plugin_load_add = "server_audit";
            server_audit_logging = "ON";
            server_audit_events = "CONNECT,QUERY_DDL";
            server_audit_excl_users = "root@localhost,mysql@localhost";
            server_audit_output_type = "syslog";
            server_audit_syslog_priority = "LOG_INFO";
          }
          // mysqlSettings;
      };

      systemd.services.mysql.serviceConfig.ExecStartPre = [
        "+${pkgs.writeShellScript "${name}-prepare-dbpass" ''
          set -eu
          ${pkgs.coreutils}/bin/install -m 0400 -o mysql -g mysql ${dbpassPath} ${dbpassRuntimePath}
        ''}"
      ];

      systemd.services.mysql.postStart = lib.mkAfter ''
        set -eu
        PASS=$(${pkgs.gnugrep}/bin/grep '^${passwordVariable}=' ${dbpassRuntimePath} | ${pkgs.coreutils}/bin/cut -d= -f2-)
        if [ -z "$PASS" ]; then
          echo "${name}-mariadb-setup: ${passwordVariable} not found in ${dbpassRuntimePath}" >&2
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
