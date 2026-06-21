# Wiring for the Tailscale ACL preserve-or-die path probe (issue #239, unit U5).
#
# Installs the check-acl-paths CLI (for hand-running before/after the U7 flip) and
# registers it as a Kuma deep probe for continuous post-cutover health. The Kuma
# monitor name is host-suffixed so doc1 AND doc2 can both run it (two server
# vantage points) without a monitor-name collision.
#
# See modules/nixos/services/probes/check-acl-paths.nix for what it checks and
# what it deliberately does NOT (the client/edge negative checks are hand-run in
# U7). Apply lives on doc1 (acl-apply.nix); this can run anywhere with monitoring.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.tailscale.aclPathProbe;
  probe = pkgs.callPackage ../probes/check-acl-paths.nix {};
in {
  options.homelab.tailscale.aclPathProbe = {
    enable = lib.mkEnableOption "Tailscale ACL preserve-or-die path probe (CLI + Kuma deep probe)";

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {ACL_PROBE_SSH_TARGET = "100.87.177.120:22";};
      description = "ACL_PROBE_* overrides for the probe targets (see check-acl-paths.nix).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [probe];

    homelab.monitoring.deepProbes = [
      {
        name = "tailscale-acl-paths-${config.networking.hostName}";
        command = "${probe}/bin/check-acl-paths";
        interval = "5m";
        # 450s Kuma interval vs 5m (300s) cadence — ~50% headroom so on-time
        # pushes don't race Kuma's deadline (see monitoring_sync.nix intervalSecs).
        intervalSecs = 450;
        timeout = "60s";
        serviceConfig.Environment = lib.mapAttrsToList (k: v: "${k}=${v}") cfg.environment;
      }
    ];
  };
}
