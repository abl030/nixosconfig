---
name: framework-lid-suspend-gsd-power
description: framework lid won't suspend = stuck GNOME gsd-power lid lock; fix is upower ignoreLid, NOT LidSwitchIgnoreInhibited
metadata:
  type: reference
---

framework's closed lid intermittently stops suspending because GNOME gsd-power
(50.1) latches a low-level `handle-lid-switch` block inhibitor with a PHANTOM
external monitor (mutter sees only builtin eDP-1) and never releases it. Trigger:
a spurious AMD s2idle glitch-wake (Framework-13-AMD quirk) re-probes displays on
resume. On systemd ≥250 a held low-level `handle-lid-switch` lock is ALWAYS
honored, so logind ignores the lid and `HandleLidSwitch` is irrelevant while it's
held.

**DO NOT** "fix" this with `services.logind.settings.Login.LidSwitchIgnoreInhibited`
— it only governs HIGH-level (sleep/idle) locks and does nothing here. We already
burned a commit on that (added + reverted, 2026-06-26).

**The fix (live):** `services.upower.ignoreLid = true` on framework (in
`modules/nixos/services/framework/sleep-then-hibernate.nix`) → UPower reports no
lid → gsd-power's lid setup is gated on `if (lid_is_present)` so it never takes
the inhibitor → logind drives lid-close natively (suspend-then-hibernate). Takes
effect after a gsd-power restart (reboot/relog). Stop-gap clear without the fix:
`killall gsd-power`.

Full RCA + the systemd-semantics trap: `docs/wiki/infrastructure/framework-lid-suspend-gsd-power.md`.
