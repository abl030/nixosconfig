This kopia every three hours will backup /photos to wasabi.
This is an interim option until we finalise our real zfs backups, but it felt too important not
to have an up-to-date offsite.

I still don't quite understand how kopia manages configurations. Because if you move your config directory, while pointing the docker compose file to the new directory, then the kopia docker image will complain that it has the wrong password for the repository. I am assuming its the remote repo? BEcause our local repo is stored in our .env file.
Long story short though is its generally just easier to imagine your kopia config living on the remote repo. Docker images and config files are ephemeral. As long as you mount all the directories in the same place here, then its just easier to re-connect to the remote repo and start again when things go wrong.

## Monitoring

Four Uptime Kuma monitors are auto-provisioned via `stackMonitors`:

- **Kopia Photos / Kopia Mum** — HTTP checks against the public URLs (accept 401 as healthy since auth is required).
- **Kopia Photos Backup / Kopia Mum Backup** — JSON query monitors hitting `/api/v1/sources` on localhost with basic auth. Uses JSONata `$count(sources[lastSnapshot.stats.errorCount > 0])` and expects `0`. If any source's last snapshot had errors, the monitor goes DOWN and triggers a Gotify notification.

Credentials are currently hardcoded in the monitor definitions (TODO: rotate and move to SOPS).

## Snapshot Verification

Daily `kopia snapshot verify` runs via systemd timers to catch silent data corruption:

- **kopia-verify-photos** — 04:00 daily, verifies 5% of files (`kopiaphotos` container)
- **kopia-verify-mum** — 06:00 daily, verifies 1% of files (`kopiamum` container, lower % due to network mount speed)

On failure, a Gotify notification is sent. Logs go to journald and flow through Alloy to Loki:

```
journalctl -u kopia-verify-photos -u kopia-verify-mum
{unit=~"kopia-verify.*"}  # Loki LogQL
```

Both services use `restartIfChanged = false` so deploys don't block waiting for a verify to finish. The `verifyPercent` parameter on `mkVerifyScript` controls the percentage per instance (defaults to 5%).
