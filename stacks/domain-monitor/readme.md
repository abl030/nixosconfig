===== ./docker/domain-monitor/readme.md =====
# Domain Monitor

A PHP-based domain monitoring tool, containerized via a custom Dockerfile and managed by NixOS.

## Architecture

- **Source:** Tracked in `flake.nix` as `domain-monitor-src`.
- **Build:** Custom `Dockerfile` (PHP 8.2 + Apache) builds on the host.
- **Sync:** On container boot, `entrypoint.sh` rsyncs the source code from the Nix Store to the writable `/var/www/html` volume, preserving the `.env` configuration.
- **Database:** MariaDB container.
- **Cron:** Systemd timer runs `cron.php` every 5 minutes via `docker exec`.

## Configuration

Secrets are managed via `sops-nix` in `domain-monitor.env`:

```ini
DB_ROOT_PASSWORD=...
DB_NAME=domainmonitor
DB_USER=dm_user
DB_PASSWORD=...
```

**Access:** `http://<host-ip>:8089`

## Updating

Updates are handled entirely through the flake. The entrypoint script automatically applies code changes on restart.

1. **Update the source lock:**
   ```bash
   nix flake update domain-monitor-src
   ```
2. **Rebuild the system:**
   ```bash
   nixos-rebuild switch --flake .#proxmox-vm
   ```

### Database Migrations
If an update requires database schema changes (e.g., the app shows SQL errors after updating), run the migration command manually inside the container:

```bash
docker exec -it domain-monitor-app php spark migrate
```
