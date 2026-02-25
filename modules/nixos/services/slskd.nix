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
        ipv4.addresses = [
          {
            address = cfg.vpnAddress;
            prefixLength = 24;
          }
        ];
      };

      # Policy routing: packets from VPN NIC use separate routing table
      # pfSense then routes this IP through WireGuard tunnel
      iproute2.enable = true;
      localCommands = ''
        # Policy routing for VPN NIC (slskd Soulseek traffic)
        ip rule del from ${cfg.vpnAddress} table 100 2>/dev/null || true
        ip rule add from ${cfg.vpnAddress} table 100 priority 100
        ip route replace default via ${cfg.gateway} dev ${cfg.vpnInterface} table 100
      '';

      firewall.allowedTCPPorts = [5030];
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

    # slskd user needs NFS media access
    users.users.slskd.extraGroups = ["users"];

    sops.secrets."slskd/env" = {
      sopsFile = config.homelab.secrets.sopsFile "slskd.env";
      format = "dotenv";
      owner = "slskd";
      mode = "0400";
    };

    homelab = {
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
