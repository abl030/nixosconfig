{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.homelab.tailscale;
in {
  imports = [
    ./subnet-priority.nix
  ];

  options.homelab.tailscale = {
    enable = lib.mkEnableOption "Homelab Tailscale configuration";

    tpmOverride = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set TS_NO_TPM=true. Required for machines that swap between Bare Metal and VM (prevents state key lockouts).";
    };

    netfilterMode = lib.mkOption {
      type = lib.types.enum ["off" "nodivert" "on"];
      default = "off";
      description = ''
        Tailscale's netfilter integration (`tailscale set --netfilter-mode`).

        DEFAULT "off": tailscaled does NOT install its `ts-input` chain with the
        blanket `-i tailscale0 -j ACCEPT` rule. That rule is jumped from INPUT
        *before* nixos-fw, so with the default "on" it silently accepts the
        ENTIRE tailnet to every listening port regardless of NixOS firewall
        config (the trap that made `trustedInterfaces=["tailscale0"]` look load-
        bearing when it was redundant). With "off", nixos-fw becomes the real
        gate: services reach the tailnet via an explicit
        interfaces.tailscale0 pinhole or nginx:443, and bare ports are dropped.
        Safe on leaf nodes — SSH(22) is global, the tailscale UDP port is open,
        and nixos-fw accepts RELATED,ESTABLISHED so outbound stays two-way.

        Set "on" for roaming workstations (epi/framework) that reach
        sunshine/vnc/etc. over the tailnet and are NOT service hosts. Hosts that
        ADVERTISE subnet routes / act as an exit node must NOT use "off" without
        adding their FORWARD/masquerade rules by hand (no fleet host does today;
        Tower is the only subnet router and it is not NixOS-managed).
        See docs/wiki/infrastructure/tailscale-untrust.md.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Base Tailscale Service
    services.tailscale = {
      enable = true;
      port = 55500;
      useRoutingFeatures = "both";
      # Make nixos-fw the real gate for the tailnet (default off; see option).
      # Applied via tailscaled-set.service -> `tailscale set --netfilter-mode`.
      extraSetFlags = ["--netfilter-mode=${cfg.netfilterMode}"];
    };

    # 2. Firewall Configuration
    networking.firewall = {
      # Allow the specific Tailscale UDP port
      allowedUDPPorts = lib.mkBefore [config.services.tailscale.port];

      # tailscale0 is deliberately NOT trusted in nixos-fw. With
      # netfilterMode="off" (our default) tailscaled no longer blanket-accepts
      # the interface either, so nixos-fw is the real gate: services reach the
      # tailnet via an explicit interfaces.tailscale0 pinhole (see syncthing,
      # sunshine, vnc) or ride nginx on 443 (the localProxy FQDNs). SSH (22)
      # lives in the GLOBAL allowedTCPPorts (openssh.openFirewall), so neither
      # the untrust nor netfilterMode=off can lock anyone out of any host.
      # Inventory + rationale: docs/wiki/infrastructure/tailscale-untrust.md
    };

    # 3. The Conditional TPM Override
    systemd.services.tailscaled.environment = lib.mkIf cfg.tpmOverride {
      TS_NO_TPM = "true";
    };

    # 4. Real readiness gate for downstream consumers.
    #
    # `tailscaled.service` calls sd_notify(READY=1) before LocalBackend
    # finishes; the interface and IPs aren't bindable for ~5-30s after
    # the unit hits `active`. NFS mounts gated only on `tailscaled.service`
    # race the readiness gap and timeout.
    #
    # `tailscale wait` (1.96+) is the upstream-blessed primitive: blocks
    # until the interface is actually bindable. Downstream units that
    # need a working tunnel should `Requires=`/`After=` this oneshot
    # instead of `tailscaled.service` directly.
    #
    # Scope: LOCAL interface bindability only. Does NOT verify any peer
    # is reachable — that's intentional. Peer reachability at boot/rebuild
    # time predicts nothing about reachability at runtime; the mount.nfs
    # call itself is the peer-reachability signal. See
    # docs/wiki/infrastructure/nfs-over-tailscale.md § "Scope of the
    # readiness gate" for why peer-ping was rejected.
    systemd.services.tailscale-wait = {
      description = "Wait for Tailscale interface to be bindable";
      after = ["tailscaled.service"];
      requires = ["tailscaled.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # systemd backstop above the CLI's own --timeout. Oneshots default
        # TimeoutStartSec to infinity, so a hung tailscale binary (deadlock,
        # SIGSTOP) would stall every downstream consumer forever.
        TimeoutStartSec = "150s";
        ExecStart = "${pkgs.tailscale}/bin/tailscale wait --timeout=120s";
      };
    };
  };
}
