# Observability Plan: OpenTelemetry Tracing & Prometheus Exporters

This document outlines the plan to implement distributed tracing via OpenTelemetry and expand Prometheus metrics collection across the homelab fleet.

## Current State

The fleet already has:
- **Loki** (logs) on igpu
- **Mimir** (metrics) on igpu
- **Tempo** (traces) on igpu — **still idle, no apps support trace export**
- **Grafana** on igpu — dashboards at logs.ablz.au
- **Alloy** on each NixOS host — shipping journald logs to Loki, node metrics to Mimir

What's implemented:
- **Immich Prometheus metrics** — scraping :8081/metrics via Alloy
- **Immich Grafana dashboard** — https://logs.ablz.au/d/immich-homelab/immich-homelab

What's missing:
- Application-level tracing (Tempo is empty — **no apps in our fleet support OTEL traces**)
- Additional application-specific Prometheus metrics

---

## Phase 1: Immich Prometheus Metrics ✅ COMPLETE

**Original Goal**: Get Immich sending traces to Tempo as proof-of-concept.

**Actual Outcome**: Discovered Immich only supports **Prometheus metrics**, not OTEL traces. Pivoted to metrics scraping.

### What We Learned

Immich has built-in OpenTelemetry support via `nestjs-otel` ([PR #7356](https://github.com/immich-app/immich/pull/7356)), but this is **metrics-only**. Traces are not currently supported ([GitHub Discussion #14062](https://github.com/immich-app/immich/discussions/14062)).

The OTEL env vars (OTEL_EXPORTER_OTLP_ENDPOINT, etc.) are for **metrics export**, not traces.

### What Was Implemented

1. **Prometheus metrics endpoint** enabled on Immich at `:8081/metrics`
   - Set `IMMICH_TELEMETRY_INCLUDE=all` in immich-server container
   - Exposed port 8081 in docker-compose.yml

2. **Alloy scrape configuration** added via new `extraScrapeTargets` option
   - Defined in `stacks/immich/docker-compose.nix` alongside stack definition
   - Stack is portable — scrape config moves with it

3. **Custom Grafana dashboard** created at https://logs.ablz.au/d/immich-homelab/immich-homelab
   - Users total (stat panel)
   - HTTP request rate by method/status (timeseries)
   - HTTP latency p95 by path (timeseries)
   - Immich version (stat panel)
   - Repository operations rate (timeseries)
   - ML health checks (timeseries)
   - Immich logs from Loki (logs panel)

### Configuration Applied

```yaml
# stacks/immich/docker-compose.yml
immich-server:
  environment:
    - IMMICH_TELEMETRY_INCLUDE=all

immich-network-holder:
  ports:
    - 8081:8081  # Prometheus metrics
```

```nix
# stacks/immich/docker-compose.nix
firewallPorts = [8081];
scrapeTargets = [
  { job = "immich"; address = "localhost:8081"; }
];
```

### Why Tempo Is Still Empty

No applications in our current fleet support OTEL trace export:
- **Immich**: Metrics only (no traces)
- **Jellyfin**: Needs investigation
- **Plex/Sonarr/Radarr/etc**: Prometheus exporters only

Tempo infrastructure is ready (OTLP receivers on 4317/4318), just waiting for an app that can send traces.

---

## Phase 2: Additional OTEL-Native Apps

After Immich is working, enable OTEL on other apps with native support.

### Jellyfin

Jellyfin has an OpenTelemetry exporter ([commit reference](https://github.com/jellyfin/jellyfin/actions/runs/8744897042)).

```yaml
environment:
  - OTEL_EXPORTER_OTLP_ENDPOINT=http://<igpu-ip>:4317
  - OTEL_SERVICE_NAME=jellyfin
```

Check Jellyfin docs/config for the exact env var names — may differ from standard OTEL SDK.

### Ollama (via instrumentation library)

Ollama itself doesn't have native OTEL, but calls can be instrumented via Python/Node clients:

- Python: `pip install opentelemetry-instrumentation-ollama`
- Use [OpenLLMetry](https://github.com/traceloop/openllmetry) for auto-instrumentation

Since we use Ollama via API calls, instrumentation would need to be in the calling application (e.g., if Open-WebUI calls Ollama).

---

## Phase 3: Prometheus Exporters

For apps without OTEL support, add Prometheus exporters to collect metrics.

### Exporter Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Application   │────▶│    Exporter     │────▶│     Mimir       │
│   (Plex, etc)   │ API │ (sidecar/standalone)  │   (via Alloy)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Priority Exporters

#### 1. Plex Exporter

**Image**: `ghcr.io/axsuul/plex-exporter` or build from [plex_exporter](https://github.com/arnarg/plex_exporter)

```yaml
plex-exporter:
  image: ghcr.io/axsuul/plex-exporter:latest
  environment:
    - PLEX_URL=http://plex:32400
    - PLEX_TOKEN=${PLEX_TOKEN}
  ports:
    - "9594:9594"
```

**Metrics**: Library sizes, active sessions, transcoding status, bandwidth

#### 2. *Arr Suite Exporter (Sonarr, Radarr, Lidarr)

**Image**: `ghcr.io/onedr0p/exportarr:latest`

```yaml
sonarr-exporter:
  image: ghcr.io/onedr0p/exportarr:latest
  command: ["sonarr"]
  environment:
    - URL=http://sonarr:8989
    - APIKEY=${SONARR_API_KEY}
  ports:
    - "9707:9707"

radarr-exporter:
  image: ghcr.io/onedr0p/exportarr:latest
  command: ["radarr"]
  environment:
    - URL=http://radarr:7878
    - APIKEY=${RADARR_API_KEY}
  ports:
    - "9708:9708"

lidarr-exporter:
  image: ghcr.io/onedr0p/exportarr:latest
  command: ["lidarr"]
  environment:
    - URL=http://lidarr:8686
    - APIKEY=${LIDARR_API_KEY}
  ports:
    - "9709:9709"
```

**Alternative**: [scraparr](https://github.com/thecfu/scraparr) — single container for all *arr apps

**Metrics**: Queue sizes, download counts, library stats, health checks

#### 3. Tautulli (Built-in)

Tautulli has a built-in Prometheus endpoint at `/api/v2?apikey=XXX&cmd=get_activity`.

Configure Alloy/Prometheus to scrape it directly — no exporter needed.

#### 4. Uptime Kuma (Built-in)

Already has `/metrics` endpoint. Just need to configure scraping.

---

## Phase 4: Alloy Scrape Configuration

Update the Alloy config on doc1/igpu to scrape the new exporter endpoints.

### Option A: Static Scrape Configs

Add to Alloy config:

```hcl
prometheus.scrape "plex" {
  targets = [{ __address__ = "plex-exporter:9594" }]
  forward_to = [prometheus.remote_write.mimir.receiver]
  job_name = "plex"
}

prometheus.scrape "sonarr" {
  targets = [{ __address__ = "sonarr-exporter:9707" }]
  forward_to = [prometheus.remote_write.mimir.receiver]
  job_name = "sonarr"
}
```

### Option B: Docker Service Discovery

If exporters run in the same podman network, use container labels for auto-discovery.

---

## Application Support Matrix

### Native OTEL Support

| App | Status | Env Vars | Notes |
|-----|--------|----------|-------|
| **Immich** | Metrics only | `IMMICH_TELEMETRY_INCLUDE=all` | Prometheus metrics on :8081. Traces NOT supported yet ([discussion](https://github.com/immich-app/immich/discussions/14062)) |
| **Jellyfin** | Partial | TBD | Has OTEL exporter, check docs |
| **Open-WebUI** | Full | `ENABLE_OTEL=true`, `OTEL_*` | Not currently deployed |
| **Grafana stack** | N/A | — | These ARE the backend |

### OTEL via Instrumentation Library

| App | Language | Library |
|-----|----------|---------|
| Ollama | Python | `opentelemetry-instrumentation-ollama` |
| Docspell | JVM | OTEL Java agent auto-instrumentation |

### Prometheus Metrics Only

| App | Exporter | Port | Notes |
|-----|----------|------|-------|
| Plex | plex_exporter | 9594 | Needs PLEX_TOKEN |
| Sonarr | exportarr | 9707 | Needs API key |
| Radarr | exportarr | 9708 | Needs API key |
| Lidarr | exportarr | 9709 | Needs API key, or built-in /metrics |
| Tautulli | built-in | — | API endpoint |
| Uptime Kuma | built-in | — | /metrics endpoint |
| Tdarr | community | — | Grafana dashboard available |

### No Known Support

| App | Notes |
|-----|-------|
| Paperless-ngx | Django — could add OTEL Python SDK |
| Mealie | FastAPI — could add OTEL Python SDK |
| Audiobookshelf | Node.js — could add OTEL Node SDK |
| Kopia | No observability features |
| Firefly III | PHP/Laravel — no native support |
| Stirling PDF | No support |
| JDownloader | No support |
| Gotify | No support |

---

## Grafana Dashboards

### Custom Dashboards (Deployed)

| App | UID | URL | Notes |
|-----|-----|-----|-------|
| Immich | immich-homelab | [Immich Homelab](https://logs.ablz.au/d/immich-homelab/immich-homelab) | Custom dashboard using `job="immich"` labels |

### Community Dashboards (Reference)

| App | Dashboard ID | URL | Notes |
|-----|-------------|-----|-------|
| Immich | 22555 | [Grafana Labs](https://grafana.com/grafana/dashboards/22555-immich-overview/) | Uses Kubernetes labels — needs adaptation |
| Plex | 9808 | [Grafana Labs](https://grafana.com/grafana/dashboards/9808-plex-server-monitoring/) | |
| Sonarr | 12530 | [Grafana Labs](https://grafana.com/grafana/dashboards/12530-sonarr-v3/) | |
| Radarr | 12896 | [Grafana Labs](https://grafana.com/grafana/dashboards/12896-radarr-v3/) | |
| Tdarr | 20388 | [Grafana Labs](https://grafana.com/grafana/dashboards/20388-tdarr/) | |
| Uptime Kuma | 18278 | [Grafana Labs](https://grafana.com/grafana/dashboards/18278-uptime-kuma/) | |

---

## Implementation Order

1. ✅ **Immich metrics** — Prometheus scraping + Grafana dashboard (DONE)
2. **Uptime Kuma metrics** — Already has /metrics, just scrape it
3. **Plex exporter** — High value, good dashboards available
4. ***Arr exporters** — Sonarr/Radarr/Lidarr monitoring
5. **Tautulli metrics** — Complements Plex data
6. **Jellyfin investigation** — Check if it actually supports OTEL traces

---

## Open Questions

- [x] Does Tempo on igpu have OTLP receiver enabled? **YES** — receivers configured for both gRPC and HTTP
- [x] What port is Tempo OTLP listening on? **4317 (gRPC) and 4318 (HTTP)** — both exposed
- [x] Do we need to open firewall ports between doc1 and igpu for OTLP? **YES** — ports 4317/4318 need to be open, done via loki stack config
- [ ] Should exporters run as sidecars in each stack or in a dedicated "monitoring" stack?
- [ ] Where to store exporter API keys? (sops secrets)
- [ ] **NEW**: Which apps actually support OTEL traces? (Current answer: possibly none in our fleet)

---

## References

- [Immich Monitoring Docs](https://docs.immich.app/features/monitoring/)
- [Immich OTEL PR #7356](https://github.com/immich-app/immich/pull/7356)
- [Grafana Alloy OTEL Collection](https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/)
- [exportarr GitHub](https://github.com/onedr0p/exportarr)
- [OpenLLMetry for Ollama](https://github.com/traceloop/openllmetry)
