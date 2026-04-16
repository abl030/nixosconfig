# Uptime Kuma Targeted Health Checks (Doc1)

Goal: prefer stable, unauthenticated health endpoints when they exist, rather than using `/` (which can return 401 or misleading 200s). Only update stacks that have a clearly documented or widely accepted health endpoint.

## Findings & Recommendations

### Immich (photos.ablz.au)
- **Recommended:** `https://photos.ablz.au/api/server/ping`
- **Why:** `/api/server-info/*` endpoints were deprecated/removed; use `/api/server/*` instead. Community reports the ping endpoint moved accordingly.
- **Sources:**
  - Immich discussion notes `/api/server-info/*` removed, use `/api/server/*`. citeturn6search4
  - Community monitoring threads reference `/api/server/ping` as the ping endpoint. citeturn6reddit46

### Stirling PDF (pdf.ablz.au)
- **Recommended:** keep `/` for now.
- **Why:** The documented health endpoint appears intended for internal/container checks and returns 401 externally; no stable public unauthenticated endpoint confirmed.

### Mealie (cooking.ablz.au)
- **Recommended:** `https://cooking.ablz.au/api/app/about`
- **Why:** The API docs expose a public “Get App Info” endpoint at `/api/app/about`, which is stable and returns 200 without auth.
- **Source:** citeturn10open0

### Jellyfin (jelly.ablz.au)
- **Recommended:** `https://jelly.ablz.au/System/Info/Public`
- **Why:** Jellyfin’s OpenAPI schema exposes `/System/Info/Public` as a public info endpoint; better than `/` which may redirect or require auth.
- **Source:** citeturn10open1


### Jellystat (jellystat.ablz.au)
- **Recommended:** `https://jellystat.ablz.au/`
- **Why:** Root returns 200 (login page). No dedicated health endpoint documented.

### watchstate (watchstate.ablz.au)
- **Recommended:** `https://watchstate.ablz.au/`
- **Why:** Root returns 200 (WebUI). No dedicated health endpoint documented.


### pfSense Exporter (internal, localhost:9945)
- **Recommended:** `http://localhost:9945/metrics?target=192.168.1.1`
- **Why:** Multi-target exporter; requires `?target=` param. Returns Prometheus text format — Kuma checks HTTP 200.

### ntopng Exporter (internal, localhost:9946)
- **Recommended:** `http://localhost:9946/metrics`
- **Why:** Exposes Prometheus text format directly on the metrics path (no auth). Kuma checks HTTP 200. Exporter pulls from ntopng via REST on pfSense.

### Gotify (gotify.ablz.au)
- **Recommended:** keep `/` for HTTP checks.
- **Why:** Official docs emphasize websocket proxy headers for Gotify, but do not document a public HTTP health endpoint. Use root + websocket support.
- **Source (websocket proxy requirements):** citeturn0search7

### WebDav (webdav.ablz.au)
- **Recommended:** keep `/` and accept 401 as healthy (already configured).
- **Why:** Standard WebDav responds with 401 when auth is required.

### Kopia (kopiaphotos.ablz.au, kopiamum.ablz.au)
- **Recommended:** keep `/` and accept 401 as healthy (already configured).
- **Why:** Kopia server status is CLI-based; no documented unauth HTTP health endpoint.
- **Source (CLI status):** citeturn3search5

### Smokeping (ping.ablz.au)
- **Recommended:** `https://ping.ablz.au/smokeping/smokeping.cgi`
- **Why:** LinuxServer’s Smokeping docs call out the main UI at `/smokeping/smokeping.cgi`; use that rather than the directory root to avoid redirects.
- **Source:** citeturn10open2

### Atuin (atuin.ablz.au), Netboot (netboot.ablz.au), Tautulli (tau.ablz.au), Uptime Kuma (status.ablz.au), Youtarr (youtarr.ablz.au), JDownloader2 (download.ablz.au), Paperless (paperless.ablz.au)
- **Recommended:** keep `/` for now.
- **Why:** No clear, unauthenticated health endpoints found in official docs during this pass.

## Next Steps
1. Update Immich monitor URL to `/api/server/ping`.
2. Update Stirling PDF monitor URL to `/api/v1/health`.
3. Keep other services on `/` (or existing paths) until a better endpoint is documented.
4. Rebuild doc1 and confirm Kuma checks remain green.
