{
  config,
  lib,
  pkgs,
  ...
}: let
  peer = "PyLCXAQT8KkM4T+dUsOQfn+Ub3pGxfGlxkIApuig+hk=";
  # Pin the Asia gateway to avoid needing public DNS before the locked tunnel
  # exists. Refresh from asia3.vpn.airdns.org when replacing this profile.
  endpoint = "103.230.144.102:1637";
  rules = pkgs.writeText "airvpn-lock.nft" ''
    table inet airvpn_lock {
      chain output {
        type filter hook output priority -100; policy accept;
        oifname "lo" accept
        oifname "airvpn" accept
        # Only the split resolver may send direct internal DNS. This prevents
        # resolved's competing Tailscale ~. domain from leaking public queries.
        meta skuid "unbound" ip daddr { 192.168.1.1, 100.100.100.100 } udp dport 53 accept
        meta skuid "unbound" ip daddr { 192.168.1.1, 100.100.100.100 } tcp dport 53 accept
        udp dport { 53, 853 } reject
        tcp dport { 53, 853 } reject
        oifname "tailscale0" accept
        ip daddr { 192.168.1.0/24, 10.20.0.0/24 } accept
        # Kernel WireGuard packets have no socket UID. Match their privileged
        # mark and pinned endpoint instead; see the epi-airvpn incident note.
        ip daddr 103.230.144.102 meta mark 51820 udp dport 1637 accept
        # Tailscale uses this mark to keep its transport outside VPN routing.
        meta skuid 0 meta mark & 0xff0000 == 0x80000 accept
        udp sport 68 udp dport 67 accept
        udp sport 546 udp dport 547 accept
        icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
        counter reject with icmpx type admin-prohibited
      }
      chain forward {
        type filter hook forward priority -100; policy accept;
        oifname "airvpn" accept
        udp dport { 53, 853 } reject
        tcp dport { 53, 853 } reject
        oifname "tailscale0" accept
        ip daddr { 192.168.1.0/24, 10.20.0.0/24 } accept
        counter reject with icmpx type admin-prohibited
      }
    }
  '';
  control = pkgs.writeShellApplication {
    name = "airvpn";
    runtimeInputs = [pkgs.networkmanager pkgs.systemd pkgs.wireguard-tools];
    text = ''
      case "''${1:-status}" in
        on|off)
          if [[ $EUID != 0 ]]; then
            exec /run/wrappers/bin/sudo "$0" "$1"
          fi
          ;;
        status) ;;
        *) echo "Usage: airvpn [on|off|status]" >&2; exit 2 ;;
      esac
      case "''${1:-status}" in
        on)
          systemctl start airvpn-lock.service
          nmcli --wait 30 connection up airvpn
          ;;
        off)
          if nmcli -t -f NAME connection show --active | ${pkgs.gnugrep}/bin/grep -qx airvpn; then
            nmcli --wait 30 connection down airvpn
          fi
          systemctl stop airvpn-lock.service
          ${pkgs.systemd}/bin/resolvectl flush-caches
          ;;
        status)
          nmcli -f NAME,TYPE,DEVICE connection show --active
          systemctl --no-pager status airvpn-lock.service || true
          ;;
      esac
    '';
  };
in {
  # On-demand workstation VPN; see docs/wiki/infrastructure/epi-airvpn.md.
  sops.secrets.airvpn = {
    sopsFile = config.homelab.secrets.sopsFile "airvpn.env";
    format = "dotenv";
    key = "";
    mode = "0400";
    restartUnits = ["NetworkManager-ensure-profiles.service"];
  };

  networking.networkmanager = {
    ensureProfiles = {
      environmentFiles = [config.sops.secrets.airvpn.path];
      profiles.airvpn = {
        connection = {
          id = "airvpn";
          type = "wireguard";
          interface-name = "airvpn";
          autoconnect = false;
        };
        wireguard = {
          private-key = "$AIRVPN_PRIVATE_KEY";
          mtu = 1320;
          fwmark = 51820;
          ip4-auto-default-route = true;
          ip6-auto-default-route = true;
        };
        "wireguard-peer.${peer}" = {
          inherit endpoint;
          preshared-key = "$AIRVPN_PRESHARED_KEY";
          preshared-key-flags = 0;
          allowed-ips = "0.0.0.0/0;::/0;";
          persistent-keepalive = 15;
        };
        ipv4 = {
          method = "manual";
          address1 = "10.136.18.126/32";
          dns = "127.0.0.55;";
          dns-search = "~.;~ablz.au;~local.com;~1.168.192.in-addr.arpa;~tail13796.ts.net;";
          dns-priority = -50;
        };
        ipv6 = {
          method = "manual";
          address1 = "fd7d:76ee:e68f:a993:39c5:f7a9:eeaa:4234/128";
        };
      };
    };
    dispatcherScripts = [
      {
        type = "pre-up";
        source = pkgs.writeShellScript "airvpn-pre-up" ''
          if [[ "$1" == airvpn && "$2" == pre-up ]]; then
            ${pkgs.systemd}/bin/systemctl start airvpn-lock.service
          fi
        '';
      }
    ];
  };

  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    # AirVPN's recursive resolver validates public DNS. Keep internal overrides
    # usable without recursive DNSSEC bootstrap escaping the tunnel.
    enableRootTrustAnchor = false;
    settings = {
      server = {
        interface = ["127.0.0.55"];
        access-control = ["127.0.0.0/8 allow"];
        module-config = "\"iterator\"";
        local-zone = ["\"1.168.192.in-addr.arpa.\" transparent"];
        hide-identity = true;
        hide-version = true;
      };
      forward-zone = [
        {
          name = ".";
          forward-addr = ["10.128.0.1" "fd7d:76ee:e68f:a993::1"];
          forward-first = false;
        }
        {
          name = "ablz.au.";
          forward-addr = ["192.168.1.1"];
        }
        {
          name = "local.com.";
          forward-addr = ["192.168.1.1"];
        }
        {
          name = "1.168.192.in-addr.arpa.";
          forward-addr = ["192.168.1.1"];
        }
        {
          name = "tail13796.ts.net.";
          forward-addr = ["100.100.100.100"];
        }
      ];
    };
  };
  # The loopback-only resolver does not need raw packet privileges.
  systemd.services.unbound.serviceConfig = {
    AmbientCapabilities = lib.mkForce ["CAP_NET_BIND_SERVICE"];
    CapabilityBoundingSet = lib.mkForce ["CAP_NET_BIND_SERVICE"];
  };

  systemd.services.airvpn-lock = {
    description = "AirVPN fail-closed egress guard (airvpn off to unlock)";
    requires = ["unbound.service"];
    after = ["unbound.service"];
    # Not tied to the connection lifecycle: loss of the interface MUST leave
    # the guard active. Only an explicit off (or reboot) removes it.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nftables}/bin/nft -f ${rules}";
      ExecStop = "${pkgs.nftables}/bin/nft delete table inet airvpn_lock";
      CapabilityBoundingSet = ["CAP_NET_ADMIN"];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = ["AF_NETLINK" "AF_UNIX"];
    };
  };
  environment.systemPackages = [control pkgs.wireguard-tools pkgs.nftables];
}
