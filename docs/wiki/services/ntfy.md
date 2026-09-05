# ntfy — self-hosted Hermes phone channel

- **Date:** 2026-08-04
- **Status:** deployed on doc2
- **Server:** `https://ntfy.ablz.au`
- **Topic:** `hermes`
- **Service:** native NixOS `services.ntfy-sh`
- **Hermes gateway:** doc1 user service `hermes-gateway.service`

ntfy is the private two-way phone channel for Hermes. It replaces the retired
Telegram bot without depending on a hosted chat provider. Hermes subscribes to
the authenticated `hermes` topic and uses it as the default delivery target for
cron and completion notifications.

## Security model

- The ntfy backend listens only on doc2 loopback and is exposed through the
  existing HTTPS `homelab.localProxy` path. nginx buffering is disabled for
  this vhost so streaming `/json` events reach Hermes immediately.
- Anonymous access is denied globally.
- One non-admin user has read/write access only to the `hermes` topic.
- The server provisions the bcrypt password hash, topic ACL, and Hermes token
  from doc2-only `secrets/ntfy-server.env`.
- Hermes receives only its endpoint, topic, allowlist, and bearer token from
  doc1-only `secrets/hosts/proxmox-vm/ntfy-gateway.env` through a systemd
  user-unit EnvironmentFile. Server provisioning values never enter Hermes.
- The same user-unit drop-in resets `ExecStart` to the deployed Hermes wrapper
  and `ExecStopPost` to that package's Python cleanup module. It also aligns
  `VIRTUAL_ENV`, bundled plugins and state-store modules with that package.
  The mutable installer unit must not select an older core after upgrades.
- The gateway PATH includes the existing Nix system and operator package
  profiles, including `uvx` and the executables used by the MCP wrappers.
  Merely providing bash/git/nix/python is insufficient for MCP discovery.
- Credentials never enter tracked `config.yaml` or mutable `~/.hermes/.env`.
- The phone password is not retained in the repository or loaded into either
  service process. ntfy stores only its one-way password hash. The configured
  phone keeps the sole usable copy; losing it requires an explicit credential
  rotation.
- The ntfy phone channel intentionally has the same effective tools as the CLI,
  including terminal, filesystem, browser, delegation, and infrastructure MCP
  access. Treat the phone credential as full operator access to doc1 and the
  wider homelab.

## Phone setup

Install the ntfy Android app, add `https://ntfy.ablz.au` as a server, and log in
as `abl030` with the provisioned operator password. The plaintext is
deliberately not recoverable from the repository; the configured phone is the
credential holder.

Subscribe to topic `hermes`. Sending a message to that topic starts or resumes a
Hermes conversation; replies arrive as push notifications. The URL resolves to
doc2's LAN address, so the phone needs home-LAN access or the existing Tailscale
subnet route.

## Operator checks

```bash
ssh doc2 'systemctl status ntfy-sh --no-pager'
curl -fsS https://ntfy.ablz.au/v1/health
systemctl --user status hermes-gateway --no-pager
hermes send ntfy:hermes "Hermes ntfy test"
```

Expected health response is JSON with `healthy: true`. A publish or subscribe
without authentication must return HTTP 401/403. The authenticated Hermes token
must publish and subscribe successfully.

## Delivery

For scheduled work, set `deliver="ntfy"`; `NTFY_HOME_CHANNEL=hermes` resolves the
default topic. Interactive agents can use `hermes send ntfy:hermes "..."` when
their process has the gateway environment, or publish through the authenticated
ntfy API.

## Recovery

The cache and auth SQLite databases are ordinary ntfy runtime state. Users,
ACLs, and tokens are declaratively re-provisioned from SOPS at startup, so a
lost doc2 system disk does not lose the channel identity. Restore by deploying
signed `nixosconfig` to doc2 and doc1, then restart the Hermes gateway.
