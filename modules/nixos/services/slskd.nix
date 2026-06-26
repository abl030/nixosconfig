{
  config,
  lib,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.slskd;
  operatorUser = hostConfig.user or "abl030";
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
      description = "Directory for completed downloads consumed by Cratedigger.";
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
      group = "music-import";
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

    systemd.tmpfiles.rules = [
      "d ${cfg.downloadDir} 0770 slskd music-import -"
      "d ${cfg.downloadDir}/incomplete 0770 slskd music-import -"
    ];

    # Slskd downloads are handed to root-run cratedigger, then Beets/operator
    # tooling needs group access after import. Keep that boundary on the
    # dedicated music-import group instead of world-writable files.
    #
    # #257: slskd is an internet-facing P2P daemon — a large attack surface —
    # yet it ran with the host's whole /mnt/* tree visible (incl.
    # /mnt/backup/pfsense, /mnt/appdata, /mnt/mum). Blank /mnt and bind only
    # its two legit paths: the download dir (rw) and the shared music library
    # (read-only — slskd serves it to peers, never writes it). A compromised
    # slskd can now reach nothing else on /mnt. RequiresMountsFor orders the
    # fail-loud binds after their mounts.
    # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
    systemd.services.slskd = {
      unitConfig.RequiresMountsFor = [cfg.downloadDir cfg.musicDir];
      serviceConfig = {
        UMask = "0002";
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.downloadDir];
        BindReadOnlyPaths = [cfg.musicDir];
      };
    };

    users = {
      groups.music-import = {};
      users.${operatorUser}.extraGroups = ["music-import"];
    };

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

      # See #253 audit. Soulseek client where peer/network errors are normal
      # operation, not an actionable fingerprint (outages surface via the
      # Kuma HTTP monitor above). NAMESPACE/bind start-failures page ONCE via
      # the fleet-wide "Service failed to start (sandbox/namespace)" alert in
      # alerting.nix — no per-service entry (storm de-collide 2026-06-26).
      monitoring.errorPatterns = []; # ^ namespace → fleet alert; real outages → Kuma
    };
  };
}
