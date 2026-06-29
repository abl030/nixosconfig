{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.prometheus;
in {
  options.homelab.prometheus = {
    enable = lib.mkEnableOption "Node exporter for Prometheus metrics";

    # Per-process metrics (ncabatoff process-exporter). On by default fleet-wide
    # so the next "what's eating RAM on host X?" question is answerable from
    # Grafana history instead of a live SSH snapshot. Scraped locally by alloy
    # (see modules/nixos/services/loki.nix); see Forgejo #12 (fleet RAM audit)
    # and docs/wiki/services/lgtm-stack.md.
    processExporter.enable =
      lib.mkEnableOption "per-process metrics (process-exporter), grouped by command name"
      // {default = true;};
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.prometheus.exporters.node = {
        enable = true;
        # BIND-ALL-INTERFACES-OK: node_exporter is a metrics scrape target pulled
        # off-host (9100 is opened in the firewall on purpose). Low-sensitivity
        # host metrics; must be reachable by the scraper, so not localhost-only.
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
    }

    (lib.mkIf cfg.processExporter.enable {
      services.prometheus.exporters.process = {
        enable = true;
        # LOCALHOST-ONLY (unlike node_exporter): process metrics carry process
        # command names — more sensitive than node metrics, and there is no
        # off-host scraper here anyway. The on-host alloy scrapes 127.0.0.1:9256
        # and remote_writes to Mimir, so the port is NOT opened in the firewall.
        listenAddress = "127.0.0.1";
        port = 9256;
        settings.process_names = [
          # Group every process by its command name ({{.Comm}}), not per-PID.
          # Bounded cardinality: ~one series-group per distinct binary on the
          # host. `cmdline = [".+"]` matches everything → nothing is dropped.
          # Yields namedprocess_namegroup_memory_bytes{groupname,memtype=...},
          # _cpu_seconds_total, _num_procs, etc. per command.
          {
            name = "{{.Comm}}";
            cmdline = [".+"];
          }
        ];
      };
    })
  ]);
}
