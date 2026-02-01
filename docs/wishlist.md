1. High priority - virtiofs backing for docker volumes
6. ~~Kopia Gotify~~ ✅ Done — JSON query monitors in Uptime Kuma check backup errorCount via API, Gotify notifies on failure
7. ~~Kopia Automate 10% checks.~~ ✅ Done — daily snapshot verify via systemd timers (photos 5% at 04:00, mum 1% at 06:00), Gotify on failure, logs to Loki
8. Dev Box
9. Runner box, so we don't backup our cache.
11. Further harden our VPN endpoints. Deluge/SLSK. Isolated network and read only perms, assume intrusion.



1. ~~Make it easier to spin up new proxmox vm's~~ **[IN PROGRESS - See vm-automation-plan.md]**
    - ✅ Git commit hardware.nix and all configs automatically
    - ✅ Template with NixOS ready (VMID 9001: NixosServerBlank)
    - ✅ Proxmox operations library (vms/proxmox-ops.sh)
    - ✅ Knowledge base for tracking VMs (docs/machines.md)
    - 🚧 Automated nixos-anywhere installation
    - 🚧 Automatic secret management (sops updatekeys)
    - **See**: `docs/vm-automation-plan.md` for full details
    - **Wishlist**: `docs/vm-automation-wishlist.md` for future enhancements
