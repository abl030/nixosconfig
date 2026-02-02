{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.prometheus;
in {
  options.homelab.prometheus = {
    enable = lib.mkEnableOption "Node exporter for Prometheus metrics";
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 9100;
      enabledCollectors = [
        "cpu"
        "diskstats"
        "filesystem"
        "loadavg"
        "meminfo"
        "netdev"
        "systemd"
        "time"
        "uname"
      ];
    };

    networking.firewall.allowedTCPPorts = [9100];
  };
}
