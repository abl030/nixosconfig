# Framework Host Notes

This host has a few suspend/resume-specific pieces to improve stability and help debugging.

## Suspend/Resume Behavior
- **Suspend mode**: Uses s2idle (deep does not work on this platform).
- **Sleep-then-hibernate**: Enabled via `homelab.framework.sleepThenHibernate.enable`.
- **Wi-Fi hibernate fix**: `homelab.framework.hibernateFix.enable` sets `mt7921e.disable_aspm=1` and unloads/reloads Mediatek modules around sleep.
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

