# Uptime Kuma API Access

## Endpoint
- Base URL: https://status.ablz.au

## API Key
- Stored in sops at `secrets/uptime-kuma-api.env`
- Decrypted path: `KUMA_API_KEY_FILE` (defaults to `/run/secrets/uptime-kuma/api`)

## Metrics (current working access)
- Uses basic auth with empty username and the API key as the password.
- The key is stored in a dotenv file; extract `KUMA_API_KEY=` first.

```sh
key=$(rg -m1 '^KUMA_API_KEY=' "${KUMA_API_KEY_FILE:-/run/secrets/uptime-kuma/api}" | cut -d= -f2-)
curl -fsS --user ":$key" https://status.ablz.au/metrics
```

## Quick Lists
### Down (status != 1)
```sh
key=$(rg -m1 '^KUMA_API_KEY=' "${KUMA_API_KEY_FILE:-/run/secrets/uptime-kuma/api}" | cut -d= -f2-)
curl -fsS --user ":$key" https://status.ablz.au/metrics | rg '^monitor_status' | awk '$NF != "1" {print}'
```

### Up (status == 1)
```sh
key=$(rg -m1 '^KUMA_API_KEY=' "${KUMA_API_KEY_FILE:-/run/secrets/uptime-kuma/api}" | cut -d= -f2-)
curl -fsS --user ":$key" https://status.ablz.au/metrics | rg '^monitor_status' | awk '$NF == "1" {print}'
```

## Notes
- The uptime-kuma-api Python wrapper expects a login token (Socket.IO), not an API key.
- Use /metrics to read monitor status with this key.
