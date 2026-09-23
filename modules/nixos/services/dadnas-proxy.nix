{
  config,
  lib,
  pkgs,
  hostConfig,
  allHosts,
  ...
}: let
  cfg = config.homelab.services.dadnasProxy;
  listenIp = hostConfig.localIp;
  caddyIp = allHosts.caddy.localIp;
  port = 15000;
  socket = "/run/dadnas-tailnet/tailscaled.sock";
  sandbox = {
    DynamicUser = true;
    User = "dadnas-tailnet";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = "";
  };
in {
  options.homelab.services.dadnasProxy.enable = lib.mkEnableOption "isolated connection to Dad's shared NAS";

  config = lib.mkIf cfg.enable {
    # A user-owned identity is required: tagged servers cannot consume ordinary
    # incoming machine shares. State is enrolled once as the share recipient.
    # See docs/wiki/services/dadnas.md for recovery and the access boundary.
    systemd.services.dadnas-tailnet = {
      description = "User-owned Tailscale connection for Dad's NAS";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig =
        sandbox
        // {
          StateDirectory = "dadnas-tailnet";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "dadnas-tailnet";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${pkgs.tailscale}/bin/tailscaled --tun=userspace-networking --statedir=/var/lib/dadnas-tailnet --socket=${socket} --port=0";
          Restart = "on-failure";
          RestartSec = "5s";
        };
    };

    # This is a fixed TCP relay, with no SOCKS/HTTP forward proxy or choice of
    # destination. Caddy retains HTTPS, Host, forwarding headers and WebSockets.
    systemd.sockets.dadnas-relay = {
      description = "Dad NAS relay for Caddy and local doc1 access";
      wantedBy = ["sockets.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      listenStreams = ["127.0.0.1:${toString port}" "${listenIp}:${toString port}"];
      socketConfig = {
        Accept = true;
        NoDelay = true;
        MaxConnections = 128;
        IPAddressDeny = "any";
        IPAddressAllow = ["localhost" listenIp caddyIp];
      };
    };
    systemd.services."dadnas-relay@" = {
      description = "Relay one connection to Dad's NAS web interface";
      requires = ["dadnas-tailnet.service"];
      after = ["dadnas-tailnet.service"];
      serviceConfig =
        sandbox
        // {
          ExecStart = "${pkgs.tailscale}/bin/tailscale --socket=${socket} nc 100.103.36.101 5000";
          StandardInput = "socket";
          StandardOutput = "inherit";
          StandardError = "journal";
          # The accepted TCP socket is inherited; only the private LocalAPI Unix
          # socket may be opened by the relay process itself.
          RestrictAddressFamilies = ["AF_UNIX"];
        };
    };

    # Keep the relay off the wider LAN and tailnet. Cullen uses Caddy's existing
    # HTTPS pinhole, never this backend port. Bind addresses come from hosts.nix.
    networking.firewall = {
      extraCommands = lib.mkIf (!config.networking.nftables.enable) ''
        iptables -A nixos-fw -p tcp -s ${caddyIp} -d ${listenIp} --dport ${toString port} -j nixos-fw-accept
      '';
      extraInputRules = lib.mkIf config.networking.nftables.enable ''
        ip saddr ${caddyIp} ip daddr ${listenIp} tcp dport ${toString port} accept
      '';
    };

    homelab.monitoring = {
      # This owns tunnel credentials only; no NAS data lives here. Fetching the
      # actual DSM login page exercises Caddy, the relay and the shared tunnel.
      monitors = [
        {
          name = "Dad NAS";
          url = "https://dadnas.ablz.au/";
        }
      ];
      errorPatterns = [
        {
          name = "Dad NAS Tailscale authentication failure";
          unit = "dadnas-tailnet.service";
          pattern = "(?i)key (expired|rejected|invalid)|auth.*rejected|NeedsLogin";
          severity = "warning";
          summary = "Dad NAS proxy needs Tailscale authentication";
        }
      ];
    };
  };
}
