# Uptime Kuma API Access

## Endpoint
- Base URL: https://status.ablz.au

## API Key (expires tomorrow)
- API key: uk1_lKnUqLfLrTwRSephZ01SkJklEYV10NM-aZKYRTyG

## Metrics (current working access)
- Uses basic auth with empty username and the API key as the password.
- Example:

```sh
curl -fsS --user ":uk1_lKnUqLfLrTwRSephZ01SkJklEYV10NM-aZKYRTyG" https://status.ablz.au/metrics
```

## Quick Lists
### Down (status != 1)
```sh
curl -fsS --user ":uk1_lKnUqLfLrTwRSephZ01SkJklEYV10NM-aZKYRTyG" https://status.ablz.au/metrics | rg '^monitor_status' | awk '$NF != "1" {print}'
```

### Up (status == 1)
```sh
curl -fsS --user ":uk1_lKnUqLfLrTwRSephZ01SkJklEYV10NM-aZKYRTyG" https://status.ablz.au/metrics | rg '^monitor_status' | awk '$NF == "1" {print}'
```

## Notes
- The uptime-kuma-api Python wrapper expects a login token (Socket.IO), not an API key.
- Use /metrics to read monitor status with this key.
