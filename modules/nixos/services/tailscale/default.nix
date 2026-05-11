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
    # See docs/wiki/infrastructure/nfs-over-tailscale.md for the full
    # pathology and the 2026-05-11 incident that drove this.
    systemd.services.tailscale-wait = {
      description = "Wait for Tailscale interface to be bindable";
      after = ["tailscaled.service"];
      requires = ["tailscaled.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.tailscale}/bin/tailscale wait --timeout=120s";
      };
    };
  };
}
