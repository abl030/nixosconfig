# Tailscale Overseer TLS Timeout (Windows)

## Summary
`overseer.ablz.au` resolves via Tailscale MagicDNS to `100.86.211.116` and ping works, but HTTPS access from Windows hangs during TLS handshake.

## What Works
- From the host running ts-caddy, SNI routing works:
  - `curl -k --resolve overseer.ablz.au:443:100.86.211.116 https://overseer.ablz.au` → `307`
- Caddy is listening on `*:80` and `*:443` inside the ts-caddy netns.
- Tailscale TCP reachability from Windows confirms connectivity:
  - `Test-NetConnection 100.86.211.116 -Port 443` → `TcpTestSucceeded: True`

## What Fails (Windows)
- `curl.exe -vk --http1.1 --resolve overseer.ablz.au:443:100.86.211.116 https://overseer.ablz.au` hangs after:
  - `Trying 100.86.211.116:443...`
  - `ALPN: curl offers http/1.1`
- `curl.exe -vk https://100.86.211.116 -H "Host: overseer.ablz.au"` fails:
  - `schannel: next InitializeSecurityContext failed: SEC_E_INTERNAL_ERROR`

## Likely Cause
- Windows Schannel TLS stack hang (not ACL, not DNS, not Caddy routing). This has happened before and a reboot previously resolved it.

## State / Files Involved
- Tailscale Caddy stack:
  - `stacks/tailscale/caddy/docker-compose.nix`
  - `stacks/tailscale/caddy/docker-compose.yml`
  - `stacks/tailscale/caddy/Caddyfile` (contains `overseer.ablz.au` reverse proxy)
- Tailscale host config:
  - `modules/nixos/services/tailscale/default.nix` (tailscale0 trusted, UDP port allowed)
- ACL provided by user is permissive (allows `*:*`).

## Evidence
- ts-caddy IP: `100.86.211.116` (from `podman exec ts-caddy tailscale status --json`)
- Caddy logs show cert management for `overseer.ablz.au` and `nixcache.ablz.au` is healthy.
- TCP/443 reachable from Windows via Tailscale, but TLS negotiation hangs before handshake completes.

## Next Steps
1. Reboot the Windows machine (historical fix).
2. If still broken, enable temporary Caddy access logs on ts-caddy to confirm TLS handshakes reach it.
3. Retry Windows curl and inspect logs.
4. If logs show no TLS reach, check Windows network/AV/SSL inspection.
5. If logs show TLS reach but no response, test with another TLS client on Windows (WSL or Git Bash `openssl s_client`).
