{
  config,
  lib,
  pkgs,
  ...
}: let
  peer = "PyLCXAQT8KkM4T+dUsOQfn+Ub3pGxfGlxkIApuig+hk=";
  # AirVPN rotates the IPs behind its gateway names. Resolve the name while
  # direct DNS still works, just before the guard starts, and use the pinned
  # address only as a fallback; see docs/wiki/infrastructure/epi-airvpn.md.
  endpointHost = "asia3.vpn.airdns.org";
  fallbackIp = "185.200.117.133";
  endpointPort = "1637";
  endpointState = "/run/airvpn/endpoint";
  isIpv4 = "^([0-9]{1,3}\\.){3}[0-9]{1,3}$";
  rules = pkgs.writeText "airvpn-lock.nft" ''
    table inet airvpn_lock {
      # The only WAN destinations kernel WireGuard transport may reach.
      set endpoints {
        type ipv4_addr
        elements = { ${fallbackIp} }
      }
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
        # mark and the resolved/fallback endpoints instead.
        ip daddr @endpoints meta mark 51820 udp dport ${endpointPort} accept
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
  # Runs as root before the guard exists: record the gateway's current IP.
  # Once the guard is active public DNS is blocked, so keep the recorded one.
  prepare = pkgs.writeShellApplication {
    name = "airvpn-prepare";
    runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.getent pkgs.gnugrep pkgs.systemd];
    text = ''
      if ! systemctl -q is-active airvpn-lock.service; then
        ip=$(timeout 5 getent ahostsv4 ${endpointHost} | awk '{ print $1; exit }' || true)
        if grep -Eq '${isIpv4}' <<<"$ip"; then
          install -d -m 0755 /run/airvpn
          echo "$ip" >${endpointState}.tmp
          mv ${endpointState}.tmp ${endpointState}
        else
          echo "airvpn: could not resolve ${endpointHost}; using recorded/fallback endpoint" >&2
        fi
      fi
      systemctl start airvpn-lock.service
    '';
  };
  # Admit the recorded endpoint through the guard and point WireGuard at it.
  apply = pkgs.writeShellApplication {
    name = "airvpn-apply-endpoint";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.iproute2 pkgs.nftables pkgs.wireguard-tools];
    text = ''
      ip=${fallbackIp}
      if [[ -r ${endpointState} ]]; then
        recorded=$(head -n1 ${endpointState})
        if grep -Eq '${isIpv4}' <<<"$recorded"; then
          ip=$recorded
        fi
      fi
      if nft list table inet airvpn_lock >/dev/null 2>&1; then
        nft add element inet airvpn_lock endpoints "{ $ip }"
      fi
      if ip link show airvpn >/dev/null 2>&1; then
        wg set airvpn peer ${peer} endpoint "$ip:${endpointPort}"
        echo "airvpn: endpoint $ip:${endpointPort}"
      fi
    '';
  };
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
          ${prepare}/bin/airvpn-prepare
          nmcli --wait 30 connection up airvpn
          ${apply}/bin/airvpn-apply-endpoint
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
          # Replaced at activation by airvpn-apply-endpoint.
          endpoint = "${fallbackIp}:${endpointPort}";
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
            ${prepare}/bin/airvpn-prepare
          fi
        '';
      }
      {
        # Desktop activations bypass the helper; apply the endpoint here too.
        type = "basic";
        source = pkgs.writeShellScript "airvpn-up" ''
          if [[ "$1" == airvpn && "$2" == up ]]; then
            ${apply}/bin/airvpn-apply-endpoint
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
    # Wants, not Requires: an unbound stop or restart must never stop or reload
    # the guard (fail-open, and it would discard the resolved endpoint).
    wants = ["unbound.service"];
    after = ["unbound.service"];
    # Not tied to the connection lifecycle: loss of the interface MUST leave
    # the guard active. Only an explicit off (or reboot) removes it.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nftables}/bin/nft -f ${rules}";
      # Re-admit the recorded endpoint whenever the guard (re)loads.
      ExecStartPost = "${apply}/bin/airvpn-apply-endpoint";
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
