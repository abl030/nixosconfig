# Framework Host Notes

This host has a few suspend/resume-specific pieces to improve stability and help debugging.

## Suspend/Resume Behavior
- **Suspend mode**: Uses s2idle (deep does not work on this platform).
- **Sleep-then-hibernate**: Enabled via `homelab.framework.sleepThenHibernate.enable`.
- **Hibernate RAM fix**: `homelab.framework.hibernateFix.enable` keeps `zswap.enabled=0`, forces the hibernate image size to `0`, and drops caches before hibernate so the kernel has enough free RAM for the write phase.
- **Wi-Fi card**: The MT7922 was replaced with an Intel AX210 on 2026-07-07. The old `mt7921e` ASPM/module-reload workaround was removed; the card is now handled by in-kernel `iwlwifi`. See `docs/wiki/infrastructure/framework-mt7921e-streaming-lag.md`.
- **NFS circuit breaker**: `nfs-suspend-prepare` stops NFS automounts and lazily unmounts NFS before sleep, then restarts automounts on resume.
- **Update wake**: `homelab.update.wakeOnUpdate = true` triggers RTC wake for auto-updates (even if not on AC), then defers updates if `checkAcPower = true`.

## Debugging: AMDGPU devcoredump capture
When the AMDGPU driver creates a devcoredump, this host captures it automatically:

- **Watcher**: `systemd.path` `amdgpu-devcoredump` monitors
  `/sys/class/drm/card1/device/devcoredump/data`.
- **Capture**: `systemd.service` `amdgpu-devcoredump` saves:
  - `/var/lib/amdgpu-devcoredump/amdgpu-devcoredump-<UTC>.bin`
  - `/var/lib/amdgpu-devcoredump/amdgpu-devcoredump-<UTC>-kernel.log`
  and logs a message via `logger -t amdgpu-devcoredump`.
- **Clear**: If `/sys/class/drm/card1/device/devcoredump/clear` is writable,
  the hook writes `1` to clear the kernel devcoredump after saving.

### Quick checks
- `journalctl -t amdgpu-devcoredump -b`
- `ls -lh /var/lib/amdgpu-devcoredump/`
- `journalctl -k -b | rg -i 'amdgpu|suspend|resume'`
