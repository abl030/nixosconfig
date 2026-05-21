1. High priority - virtiofs backing for docker volumes
6. ~~Kopia Gotify~~ ✅ Done — JSON query monitors in Uptime Kuma check backup errorCount via API, Gotify notifies on failure
7. ~~Kopia Automate 10% checks.~~ ✅ Done — daily snapshot verify via systemd timers (photos 5% at 04:00, mum 1% at 06:00), Gotify on failure, logs to Loki
8. Dev Box
9. Runner box, so we don't backup our cache.
11. Further harden our VPN endpoints. Deluge/SLSK. Isolated network and read only perms, assume intrusion.



1. ~~Make it easier to spin up new proxmox vm's~~ **[ABANDONED 2026-05-21]** — Tofu/Terranix automation removed; provisioning is now manual via Proxmox UI. Revisit as a Proxmox MCP sub-agent if/when worth it.
