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
  };

  config = lib.mkIf cfg.enable {
    # 1. Base Tailscale Service
    services.tailscale = {
      enable = true;
      port = 55500;
      useRoutingFeatures = "both";
    };

    # 2. Firewall Configuration
    networking.firewall = {
      # Allow the specific Tailscale UDP port
      allowedUDPPorts = lib.mkBefore [config.services.tailscale.port];
      # Trust the interface
      trustedInterfaces = ["tailscale0"];
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
