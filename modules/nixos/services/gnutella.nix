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
  guiConfigFile = "${cfg.dataDir}/config_gui";
  guiGeometry = "${toString cfg.guiWidth}x${toString cfg.guiHeight}+0+0";
  guiResolution = "${toString cfg.guiWidth}x${toString cfg.guiHeight}";

  configureScript = pkgs.writeShellScript "gtk-gnutella-configure" ''
    set -eu

    umask 0077
    touch ${lib.escapeShellArg configFile}
    touch ${lib.escapeShellArg guiConfigFile}

    upsert() {
      file="$1"
      key="$2"
      value="$3"

      if grep -Eq "^[[:space:]]*#?[[:space:]]*''${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*''${key}[[:space:]]*=.*|''${key} = ''${value}|" "$file"
      else
        printf '%s = %s\n' "$key" "$value" >> "$file"
      fi
    }

    upsert ${lib.escapeShellArg configFile} listen_port ${toString cfg.listenPort}
    upsert ${lib.escapeShellArg configFile} network_protocol 4
    upsert ${lib.escapeShellArg configFile} configured_peermode 0
    upsert ${lib.escapeShellArg configFile} enable_g2 TRUE
    upsert ${lib.escapeShellArg configFile} enable_upnp FALSE
    upsert ${lib.escapeShellArg configFile} enable_natpmp FALSE
    upsert ${lib.escapeShellArg configFile} store_downloading_files_to ${lib.escapeShellArg "\"${cfg.dataDir}/incomplete\""}
    upsert ${lib.escapeShellArg configFile} move_downloading_files_to ${lib.escapeShellArg "\"${cfg.dataDir}/complete\""}
    upsert ${lib.escapeShellArg configFile} move_corrupted_files_to ${lib.escapeShellArg "\"${cfg.dataDir}/corrupt\""}
    upsert ${lib.escapeShellArg configFile} shared_dirs ${lib.escapeShellArg "\"\""}

    # gtk-gnutella persists the browser-resized Xpra window dimensions. Keep
    # the POC UI large enough to click and type into reliably.
    upsert ${lib.escapeShellArg guiConfigFile} window_coords "0,0,${toString cfg.guiWidth},${toString cfg.guiHeight}"
    upsert ${lib.escapeShellArg guiConfigFile} widths_nodes "130,50,120,20,30,30,80,600"
    upsert ${lib.escapeShellArg guiConfigFile} widths_file_info "240,80,80,80,80,80,80,80,80,300"
    upsert ${lib.escapeShellArg guiConfigFile} widths_sources "120,120,120,120,120,400"
    upsert ${lib.escapeShellArg guiConfigFile} widths_search_results "240,60,80,80,50,140,360,40,40,40,40,40,40,40,40,40,40,0,0"
    upsert ${lib.escapeShellArg guiConfigFile} widths_search_stats "200,80,700"
    upsert ${lib.escapeShellArg guiConfigFile} widths_ul_stats "200,80,80,80,80,80,500"
    upsert ${lib.escapeShellArg guiConfigFile} widths_uploads "200,120,40,80,80,80,500,0"
    upsert ${lib.escapeShellArg guiConfigFile} widths_gnet_stats_msg "120,60,60,60,60,60,60,650"
    upsert ${lib.escapeShellArg guiConfigFile} widths_gnet_stats_fc "120,60,60,60,60,60,60,60,60,500"
    upsert ${lib.escapeShellArg guiConfigFile} widths_gnet_stats_horizon "60,80,80,700"
    upsert ${lib.escapeShellArg guiConfigFile} widths_gnet_stats_drop_reasons "240,700"
    upsert ${lib.escapeShellArg guiConfigFile} widths_gnet_stats_recv "120,60,60,60,60,60,60,60,60,500"
    upsert ${lib.escapeShellArg guiConfigFile} widths_hcache "120,80,80,700"
    upsert ${lib.escapeShellArg guiConfigFile} widths_gnet_stats_general "240,700"

    chmod 0600 ${lib.escapeShellArg configFile} ${lib.escapeShellArg guiConfigFile}
  '';

  startScript = pkgs.writeShellScript "gtk-gnutella-xpra" ''
    set -eu

    export GTK_GNUTELLA_DIR=${lib.escapeShellArg cfg.dataDir}
    export HOME=${lib.escapeShellArg cfg.dataDir}
    export XDG_RUNTIME_DIR=/run/gtk-gnutella
    export NO_AT_BRIDGE=1

    exec ${pkgs.xpra}/bin/xpra start :${toString cfg.display} \
      --daemon=no \
      --systemd-run=no \
      --use-display=no \
      --bind-tcp=127.0.0.1:${toString cfg.webPort} \
      --html=${pkgs.xpra-html5}/share/xpra/www \
      --http=yes \
      --readonly=no \
      --keyboard-sync=yes \
      --keyboard-layout=us \
      --resize-display=${guiResolution} \
      --dpi=96 \
      --mdns=no \
      --dbus=no \
      --control=no \
      --shell=no \
      --start-new-commands=no \
      --file-transfer=no \
      --open-files=no \
      --open-url=no \
      --printing=no \
      --clipboard=no \
      --notifications=no \
      --audio=no \
      --pulseaudio=no \
      --speaker=off \
      --microphone=off \
      --webcam=no \
      --tray=no \
      --terminate-children=yes \
      --exit-with-children=yes \
      --start-child="${pkgs.gtkgnutella}/bin/gtk-gnutella --geometry ${guiGeometry} --no-dbus --no-supervise"
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

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 14546;
      description = "Loopback Xpra web port exposed via homelab.localProxy.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "gnutella.ablz.au";
      description = "Browser FQDN for the gtk-gnutella GUI.";
    };

    display = lib.mkOption {
      type = lib.types.int;
      default = 46;
      description = "Xpra display number for the gtk-gnutella GUI session.";
    };

    guiWidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1280;
      description = "Default gtk-gnutella GUI window width in the browser session.";
    };

    guiHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Default gtk-gnutella GUI window height in the browser session.";
    };

    tailscaleOnly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Expose the browser GUI only on the host's Tailscale address.";
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
    environment.systemPackages = [
      pkgs.gtkgnutella
      pkgs.xpra
      pkgs.xpra-html5
    ];

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
        pkgs.xauth
      ];

      preStart = "${configureScript}";

      serviceConfig = {
        Type = "simple";
        User = "gnutella";
        Group = "gnutella";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${startScript}";
        ExecStop = "${shutdownScript}";
        Restart = "always";
        RestartSec = "10s";
        RuntimeDirectory = "gtk-gnutella";
        RuntimeDirectoryMode = "0700";

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

    homelab = {
      localProxy.hosts = [
        {
          host = cfg.fqdn;
          port = cfg.webPort;
          websocket = true;
          inherit (cfg) tailscaleOnly;
        }
      ];

      monitoring.monitors = [
        {
          name = "gtk-gnutella GUI";
          url = "https://${cfg.fqdn}/";
        }
      ];

      monitoring.errorPatterns = [
        {
          name = "gtk-gnutella-gui";
          unit = "gtk-gnutella.service";
          pattern = "(?i)(address already in use|cannot bind|failed to bind|fatal|segmentation fault|failed to start child)";
          severity = "warning";
          summary = "gtk-gnutella GUI/Xpra wrapper is failing on doc2";
        }
      ];
    };
  };
}
