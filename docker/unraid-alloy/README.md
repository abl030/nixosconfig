# Unraid Alloy

Ships tower's syslog and Docker container logs to Loki, plus node_exporter
metrics to Mimir — all via HTTPS FQDNs that follow wherever the LGTM stack
currently lives (doc2 as of April 2026).

Deploy: `./deploy.sh` (scps `docker-compose.yml` + `config.alloy` to
`/boot/config/alloy/` on tower and runs `docker compose up -d`). After config
changes, `docker compose restart alloy` on tower to pick them up — alloy
doesn't auto-reload bind-mounted configs.

Targets live in `config.alloy`:
- Logs → `https://loki.ablz.au/loki/api/v1/push`
- Metrics → `https://mimir.ablz.au/api/v1/push`

See `docs/wiki/services/lgtm-stack.md` for architecture.
