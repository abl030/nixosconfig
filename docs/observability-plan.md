# Observability Plan: OpenTelemetry Tracing & Prometheus Exporters

This document outlines the plan to implement distributed tracing via OpenTelemetry and expand Prometheus metrics collection across the homelab fleet.

## Current State

The fleet already has:
- **Loki** (logs) on igpu
- **Mimir** (metrics) on igpu
- **Tempo** (traces) on igpu — currently idle, no apps sending traces
- **Grafana** on igpu — dashboards at logs.ablz.au
- **Alloy** on each NixOS host — shipping journald logs to Loki, node metrics to Mimir

What's missing:
- Application-level tracing (Tempo is empty)
- Application-specific Prometheus metrics (beyond node-exporter)

---

## Phase 1: Immich OpenTelemetry Tracing

**Goal**: Get Immich sending traces to Tempo as proof-of-concept.

### Immich OTEL Support

Immich has built-in OpenTelemetry support via `nestjs-otel` ([PR #7356](https://github.com/immich-app/immich/pull/7356)). It instruments:
- HTTP requests
- Postgres queries
- Redis operations
- NestJS internals

### Configuration

Add these environment variables to the immich-server container:

```yaml
environment:
  # Enable telemetry collection
  - IMMICH_TELEMETRY_INCLUDE=all

  # OpenTelemetry configuration
  - OTEL_EXPORTER_OTLP_ENDPOINT=http://<igpu-ip>:4317
  - OTEL_TRACES_EXPORTER=otlp
  - OTEL_SERVICE_NAME=immich

  # Optional: Also export metrics via OTEL (in addition to /metrics endpoint)
  - OTEL_METRICS_EXPORTER=otlp
```

### Implementation Steps

1. Verify Tempo is accepting OTLP on igpu:
   - Check `docker-compose.yml` in loki stack exposes port 4317 (gRPC) or 4318 (HTTP)
   - Tempo config should have `otlp` receiver enabled

2. Update `stacks/immich/docker-compose.yml`:
   - Add OTEL environment variables to immich-server
   - Add OTEL environment variables to immich-machine-learning (if supported)

3. Restart Immich stack on doc1

4. Verify in Grafana:
   - Navigate to Explore → Tempo
   - Search for `service.name = immich`
   - Should see traces for photo uploads, API calls, ML inference

### Notes

- Documentation mainly covers Prometheus metrics; OTEL tracing is less documented
- Some users report initialization errors with `@opentelemetry/api` duplicate registration
- If issues occur, try `OTEL_TRACES_EXPORTER=otlp` without metrics exporter first

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

### Existing Community Dashboards

| App | Dashboard ID | URL |
|-----|-------------|-----|
| Immich | 22555 | [Grafana Labs](https://grafana.com/grafana/dashboards/22555-immich-overview/) |
| Plex | 9808 | [Grafana Labs](https://grafana.com/grafana/dashboards/9808-plex-server-monitoring/) |
| Sonarr | 12530 | [Grafana Labs](https://grafana.com/grafana/dashboards/12530-sonarr-v3/) |
| Radarr | 12896 | [Grafana Labs](https://grafana.com/grafana/dashboards/12896-radarr-v3/) |
| Tdarr | 20388 | [Grafana Labs](https://grafana.com/grafana/dashboards/20388-tdarr/) |
| Uptime Kuma | 18278 | [Grafana Labs](https://grafana.com/grafana/dashboards/18278-uptime-kuma/) |

---

## Implementation Order

1. **Immich OTEL** — Prove the tracing pipeline works
2. **Uptime Kuma metrics** — Already has /metrics, just scrape it
3. **Plex exporter** — High value, good dashboards available
4. ***Arr exporters** — Sonarr/Radarr/Lidarr monitoring
5. **Tautulli metrics** — Complements Plex data
6. **Jellyfin OTEL** — If tracing works well with Immich

---

## Open Questions

- [ ] Does Tempo on igpu have OTLP receiver enabled? Check loki stack docker-compose
- [ ] What port is Tempo OTLP listening on? (4317 gRPC vs 4318 HTTP)
- [ ] Do we need to open firewall ports between doc1 and igpu for OTLP?
- [ ] Should exporters run as sidecars in each stack or in a dedicated "monitoring" stack?
- [ ] Where to store exporter API keys? (sops secrets)

---

## References

- [Immich Monitoring Docs](https://docs.immich.app/features/monitoring/)
- [Immich OTEL PR #7356](https://github.com/immich-app/immich/pull/7356)
- [Grafana Alloy OTEL Collection](https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/)
- [exportarr GitHub](https://github.com/onedr0p/exportarr)
- [OpenLLMetry for Ollama](https://github.com/traceloop/openllmetry)
