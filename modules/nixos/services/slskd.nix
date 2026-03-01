{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.slskd;
in {
  options.homelab.services.slskd = {
    enable = lib.mkEnableOption "slskd Soulseek client with VPN-routed NIC";

    vpnAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.36";
      description = "IP address on the VPN-routed second NIC.";
    };

    vpnInterface = lib.mkOption {
      type = lib.types.str;
      default = "ens19";
      description = "Network interface name for the VPN-routed NIC (Proxmox 2nd vNIC).";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.1";
      description = "Default gateway for the VPN routing table.";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Temp/slskd";
      description = "Directory for completed downloads (shared with Lidarr).";
    };

    musicDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Music/AI";
      description = "Music library directory to share on Soulseek.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking = {
      # Second NIC configuration — VPN-routed by pfSense policy routing
      interfaces.${cfg.vpnInterface} = {
        useDHCP = false; # Static IP only — no DHCP lease on VPN NIC
        ipv4.addresses = [
          {
            address = cfg.vpnAddress;
            prefixLength = 24;
          }
        ];
      };

      # Policy routing: all traffic from the slskd user goes through VPN table.
      # Source-IP routing alone doesn't work because slskd binds to 0.0.0.0
      # and the kernel picks the main NIC IP as source. UID-based routing
      # catches all slskd outbound traffic regardless of source address.
      # pfSense then policy-routes the VPN NIC IP through WireGuard tunnel.
      iproute2.enable = true;
      localCommands = ''
        # Wait for both NICs to have addresses before configuring routing.
        # At early boot, localCommands may run before DHCP/static assignment.
        for i in $(seq 1 30); do
          main_ip=$(ip -4 addr show ens18 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
          vpn_ip=$(ip -4 addr show ${cfg.vpnInterface} 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
          [ -n "$main_ip" ] && [ -n "$vpn_ip" ] && break
          sleep 1
        done

        # Fix subnet routing: both NICs share 192.168.1.0/24, so the kernel
        # may pick ens19 (VPN NIC) for the connected route. Force LAN traffic
        # through ens18 (main NIC) so NFS, DNS, etc. don't get VPN-routed.
        ip route replace 192.168.1.0/24 dev ens18 src "$main_ip" table main

        # VPN routing table: ens19 needs its own connected route for the
        # gateway, since we moved the main table's connected route to ens18.
        ip route replace 192.168.1.0/24 dev ${cfg.vpnInterface} src ${cfg.vpnAddress} table 100
        ip route replace default via ${cfg.gateway} dev ${cfg.vpnInterface} table 100

        # UID-based routing: all slskd traffic → VPN table
        # Resolve UID at runtime since NixOS assigns system UIDs dynamically
        slskd_uid=$(id -u slskd 2>/dev/null || echo "")
        if [ -n "$slskd_uid" ]; then
          ip rule del uidrange "$slskd_uid"-"$slskd_uid" table 100 2>/dev/null || true
          ip rule add uidrange "$slskd_uid"-"$slskd_uid" table 100 priority 100
        fi
        # Also keep source-IP rule as backup (for anything explicitly bound to VPN NIC)
        ip rule del from ${cfg.vpnAddress} table 100 2>/dev/null || true
        ip rule add from ${cfg.vpnAddress} table 100 priority 101
      '';

      # Web UI port 5030 intentionally NOT opened — accessed via nginx (localProxy) only
    };

    services.slskd = {
      enable = true;
      domain = null; # We use homelab.localProxy instead of upstream nginx
      openFirewall = true; # Soulseek listen port
      environmentFile = config.sops.secrets."slskd/env".path;
      settings = {
        soulseek = {
          listen_port = 50300;
          description = "NixOS slskd on doc2";
        };
        directories = {
          downloads = cfg.downloadDir;
          incomplete = "${cfg.downloadDir}/incomplete";
        };
        shares.directories = [cfg.musicDir];
        web.port = 5030;
      };
    };

    # Wait for NFS before starting (downloads + shares are on NFS)
    systemd.services.slskd = {
      after = ["mnt-data.mount"];
      requires = ["mnt-data.mount"];
    };

    # slskd user needs NFS media access
    users.users.slskd.extraGroups = ["users"];

    sops.secrets."slskd/env" = {
      sopsFile = config.homelab.secrets.sopsFile "slskd.env";
      format = "dotenv";
      owner = "slskd";
      mode = "0400";
    };

    # Upstream slskd module uses ProtectSystem=strict + ReadWritePaths to
    # whitelist NFS paths. But ReadWritePaths triggers mount namespace setup
    # which fails on stale NFS handles (same bug we fixed on soularr).
    # Disable ProtectSystem so ReadWritePaths isn't needed at all.
    # The slskd user is already sandboxed (PrivateUsers, NoNewPrivileges, etc.)
    # and only has NFS write access via extraGroups = ["users"].
    systemd.services.slskd.serviceConfig = {
      ProtectSystem = lib.mkForce false;
      ReadWritePaths = lib.mkForce [];
      ReadOnlyPaths = lib.mkForce [];
    };

    homelab = {
      nfsWatchdog.slskd.path = cfg.downloadDir;

      localProxy.hosts = [
        {
          host = "slskd.ablz.au";
          port = 5030;
        }
      ];

      monitoring.monitors = [
        {
          name = "slskd";
          url = "https://slskd.ablz.au/health";
        }
      ];
    };
  };
}
