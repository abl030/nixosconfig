# LGTM Observability Stack

Loki, Grafana, Tempo, Mimir — deployed as a rootless Podman compose service on **igpu** (192.168.1.33).

## Components

| Service | Port | URL | Purpose |
|---------|------|-----|---------|
| Grafana | 3001 | logs.ablz.au | Dashboards and exploration |
| Loki | 3100 | loki.ablz.au | Log aggregation |
| Tempo | 3200, 4317, 4318 | tempo.ablz.au | Distributed tracing (OTLP) |
| Mimir | 9009 | mimir.ablz.au | Prometheus metrics storage |
| Loki-MCP | 8081 | loki-mcp.ablz.au | Claude/Codex log query integration |

## Log Shipping (Alloy)

Each NixOS host runs Grafana Alloy (`homelab.loki`) which ships:
- **journald** logs with labels: `unit`, `priority`, `transport`, `container`
- **Prometheus node_exporter** metrics to Mimir
- **syslog** (optional, enabled per-host) for network devices

Config: `modules/nixos/services/loki.nix`

## Syslog Receiver

### Overview

Alloy's `loki.source.syslog` listens on port **1514** (UDP+TCP) for external syslog sources. Currently receives logs from pfSense (192.168.1.1). Enabled on igpu via `homelab.loki.syslogReceiver.enable`.

### pfSense Syslog Format

pfSense sends BSD syslog (RFC 3164). Alloy's `syslog_format = "rfc3164"` is required — the default RFC 5424 parser also fails to extract hostname from pfSense messages.

### Hostname Label Extraction

Alloy's syslog source exposes several internal labels. Here's what works and what doesn't for pfSense BSD syslog:

| Label | Populated? | Value | Notes |
|-------|-----------|-------|-------|
| `__syslog_message_hostname` | No | (empty) | Broken for both rfc3164 and default parser with pfSense messages |
| `__syslog_message_app_name` | Yes | `filterlog`, `dhcpd`, etc. | Works reliably |
| `__syslog_message_severity` | Yes | `informational`, `warning`, etc. | Works reliably |
| `__syslog_message_facility` | Yes | `local0`, `auth`, etc. | Works reliably |
| `__syslog_connection_hostname` | Yes | `pfsense.local.com.` | Reverse DNS of sender IP; includes trailing dot |
| `__syslog_connection_ip_address` | Yes | `192.168.1.1` | Raw source IP from UDP socket; always populated |

**Current approach**: Map `__syslog_connection_ip_address` via regex relabel rule to produce a clean `host=pfsense` label. This is extensible — add more rules for additional syslog sources.

### Adding a New Syslog Source

1. Configure the device to send syslog to igpu's IP (192.168.1.33) on port 1514/UDP
2. Add a relabel rule in the `syslogBlocks` section of `modules/nixos/services/loki.nix`:

```alloy
rule {
  source_labels = ["__syslog_connection_ip_address"]
  regex         = "192\\.168\\.1\\.X"
  replacement   = "device-name"
  target_label  = "host"
}
```

3. Deploy to igpu

### Gotchas

- **pfSense syslogd stalls**: After Alloy restarts, pfSense's syslogd can stop sending logs silently. Fix: toggle remote logging off/on in pfSense (Status > System Logs > Settings), or via API:

```bash
# Disable
curl -X PATCH ... '{"enableremotelogging": false}'
# Re-enable
curl -X PATCH ... '{"enableremotelogging": true, "remoteserver": "192.168.1.33:1514", ...}'
```

- **`use_incoming_timestamp`**: Do NOT use this with rfc3164 pfSense messages. pfSense sends timestamps without timezone info, causing Alloy to interpret them as UTC and creating ~8h offset (for AWST). Let Alloy use its own clock instead.

- **Empty hostname labels break ingestion**: If a relabel rule produces an empty `host` label, Loki silently drops the entries. This is why `__syslog_message_hostname` (always empty for pfSense) was overwriting the label with nothing and logs appeared to stop.

## Retention

- Loki: 744 hours (31 days), TSDB storage with filesystem backend
- Compactor runs retention enforcement

## Secrets

Encrypted in `secrets/loki.env` (sops-nix):
- `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`
- `LOKI_USERNAME`, `LOKI_PASSWORD`
