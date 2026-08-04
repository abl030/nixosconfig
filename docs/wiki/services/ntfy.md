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
  existing HTTPS `homelab.localProxy` path.
- Anonymous access is denied globally.
- One non-admin user has read/write access only to the `hermes` topic.
- The server provisions the bcrypt password hash, topic ACL, and Hermes token
  from doc2-only `secrets/ntfy-server.env`.
- Hermes receives only its endpoint, topic, allowlist, and bearer token from
  doc1-only `secrets/hosts/proxmox-vm/ntfy-gateway.env` through a systemd
  user-unit EnvironmentFile. Server provisioning values never enter Hermes.
- Credentials never enter tracked `config.yaml` or mutable `~/.hermes/.env`.
- The phone password is retained separately in the doc1-only encrypted
  `secrets/hosts/proxmox-vm/ntfy-phone-password.env`; it is not loaded into
  either service process. Never paste it into docs, tickets, or transcripts.
- The ntfy phone channel intentionally omits terminal, filesystem, code
  execution, delegation, browser, and all MCP/infrastructure-control toolsets.
  A lost phone credential therefore does not become remote shell access to
  doc1.

## Phone setup

Install the ntfy Android app, add `https://ntfy.ablz.au` as a server, and log in
as `abl030`. Retrieve the password locally on doc1 without printing it into an
agent transcript:

```bash
cd ~/nixosconfig
sops -d --extract '["NTFY_PHONE_PASSWORD"]' \
  secrets/hosts/proxmox-vm/ntfy-phone-password.env
```

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
