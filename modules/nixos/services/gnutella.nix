{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.gnutella;

  # POC notes, shell commands, and headless-search caveat:
  # docs/wiki/services/gtk-gnutella-poc.md
  configFile = "${cfg.dataDir}/config_gnet";

  configureScript = pkgs.writeShellScript "gtk-gnutella-configure" ''
    set -eu

    umask 0077
    touch ${lib.escapeShellArg configFile}

    upsert() {
      key="$1"
      value="$2"

      if grep -Eq "^[[:space:]]*#?[[:space:]]*''${key}[[:space:]]*=" ${lib.escapeShellArg configFile}; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*''${key}[[:space:]]*=.*|''${key} = ''${value}|" ${lib.escapeShellArg configFile}
      else
        printf '%s = %s\n' "$key" "$value" >> ${lib.escapeShellArg configFile}
      fi
    }

    upsert listen_port ${toString cfg.listenPort}
    upsert configured_peermode 0
    upsert enable_g2 TRUE
    upsert enable_upnp FALSE
    upsert enable_natpmp FALSE
    upsert store_downloading_files_to ${lib.escapeShellArg "\"${cfg.dataDir}/incomplete\""}
    upsert move_downloading_files_to ${lib.escapeShellArg "\"${cfg.dataDir}/complete\""}
    upsert move_corrupted_files_to ${lib.escapeShellArg "\"${cfg.dataDir}/corrupt\""}
    upsert shared_dirs ${lib.escapeShellArg "\"\""}

    chmod 0600 ${lib.escapeShellArg configFile}
  '';

  shutdownScript = pkgs.writeShellScript "gtk-gnutella-shutdown" ''
    set -eu

    export GTK_GNUTELLA_DIR=${lib.escapeShellArg cfg.dataDir}
    export HOME=${lib.escapeShellArg cfg.dataDir}

    printf 'shutdown\n' | ${pkgs.gtkgnutella}/bin/gtk-gnutella --shell || true
  '';
in {
  options.homelab.services.gnutella = {
    enable = lib.mkEnableOption "gtk-gnutella POC client on the VPN-routed NIC";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gtk-gnutella";
      description = "State directory for gtk-gnutella configuration and transient downloads.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 56346;
      description = "TCP/UDP Gnutella listen port exposed only on the VPN-routed interface.";
    };

    vpnAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.36";
      description = "IP address on the VPN-routed second NIC.";
    };

    vpnInterface = lib.mkOption {
      type = lib.types.str;
      default = "ens19";
      description = "Network interface name for the VPN-routed NIC.";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.1";
      description = "Default gateway for the VPN routing table.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [pkgs.gtkgnutella];

    users = {
      groups.gnutella = {};
      users.gnutella = {
        isSystemUser = true;
        group = "gnutella";
        home = cfg.dataDir;
        createHome = false;
        description = "gtk-gnutella POC client";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 gnutella gnutella -"
      "d ${cfg.dataDir}/complete 0750 gnutella gnutella -"
      "d ${cfg.dataDir}/corrupt 0750 gnutella gnutella -"
      "d ${cfg.dataDir}/incomplete 0750 gnutella gnutella -"
    ];

    networking = {
      iproute2.enable = true;

      # Route all gtk-gnutella traffic through the second NIC. pfSense then
      # policy-routes 192.168.1.36 through AirVPN via the MV_VPN_IPS alias.
      localCommands = ''
        for i in $(seq 1 30); do
          main_ip=$(ip -4 addr show ens18 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
          vpn_ip=$(ip -4 addr show ${cfg.vpnInterface} 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
          [ -n "$main_ip" ] && [ -n "$vpn_ip" ] && break
          sleep 1
        done

        ip route replace 192.168.1.0/24 dev ens18 src "$main_ip" table main
        ip route replace 192.168.1.0/24 dev ${cfg.vpnInterface} src ${cfg.vpnAddress} table 100
        ip route replace default via ${cfg.gateway} dev ${cfg.vpnInterface} table 100

        gnutella_uid=$(id -u gnutella 2>/dev/null || echo "")
        if [ -n "$gnutella_uid" ]; then
          ip rule del uidrange "$gnutella_uid"-"$gnutella_uid" table 100 2>/dev/null || true
          ip rule add uidrange "$gnutella_uid"-"$gnutella_uid" table 100 priority 102
        fi
      '';

      firewall.interfaces.${cfg.vpnInterface} = {
        allowedTCPPorts = [cfg.listenPort];
        allowedUDPPorts = [cfg.listenPort];
      };
    };

    systemd.services.gtk-gnutella = {
      description = "gtk-gnutella POC client";
      documentation = ["man:gtk-gnutella(1)"];
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      environment = {
        GTK_GNUTELLA_DIR = cfg.dataDir;
        HOME = cfg.dataDir;
      };

      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
      ];

      preStart = "${configureScript}";

      serviceConfig = {
        Type = "simple";
        User = "gnutella";
        Group = "gnutella";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${pkgs.gtkgnutella}/bin/gtk-gnutella --topless --no-dbus --no-supervise";
        ExecStop = shutdownScript;
        Restart = "on-failure";
        RestartSec = "10s";

        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
        UMask = "0077";
      };
    };

    homelab.monitoring.errorPatterns = [
      {
        name = "gtk-gnutella-listener";
        unit = "gtk-gnutella.service";
        pattern = "(?i)(address already in use|cannot bind|failed to bind|fatal|segmentation fault)";
        severity = "warning";
        summary = "gtk-gnutella POC listener is failing on doc2";
      }
    ];
  };
}
