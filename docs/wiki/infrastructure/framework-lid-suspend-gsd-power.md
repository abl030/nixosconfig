# Framework lid-close won't suspend — GNOME gsd-power stuck lid inhibitor

> **Status:** FIXED (2026-06-26) — `services.upower.ignoreLid = true` on framework, so
> **logind owns the lid, not GNOME**. See `modules/nixos/services/framework/sleep-then-hibernate.nix`.
>
> **Hardware/versions:** Framework 13 AMD · NixOS 26.11 · GNOME Shell 50.2 / gnome-settings-daemon 50.1 (Wayland) · systemd 260 · upower 1.91.1.

## ⚠️ READ THIS FIRST — the trap

**Do NOT try to fix "lid won't suspend" by setting `services.logind.settings.Login.LidSwitchIgnoreInhibited = "no"` (or `"yes"`).** It is a red herring and we already burned a commit on it (added + reverted, #032cc90a → #d1cb6885).

On **systemd ≥250** (`logind.conf(5)`, verbatim):

> Low level inhibitor locks (`handle-power-key` … **`handle-lid-switch`** …) are **always honored, irrespective of this setting**. … If a low-level inhibitor lock is taken, **logind will not take any action when that key or switch is triggered and the `Handle*=` settings are irrelevant.**

GNOME holds exactly a **`handle-lid-switch`** lock. So while it's held, *no* value of `LidSwitchIgnoreInhibited` and *no* `HandleLidSwitch=` does anything. `LidSwitchIgnoreInhibited` only governs **high-level** (`sleep`/`idle`/`shutdown`) locks — a different thing entirely.

## Symptom

A closed lid **intermittently** stops suspending. Journal shows `systemd-logind: Lid closed.` followed by **nothing** (no `Suspending…`). `systemd-inhibit --list` shows:

```
abl030  …  .gsd-power-wrap  handle-lid-switch  "External monitor attached or configuration changed recently"  block
```

…even though **no external monitor is attached** (`mutter GetCurrentState` and DRM both show only the builtin `eDP-1`, `is-builtin: true`). Relog/reboot clears it; then it comes back later.

## Root cause

GNOME's `gsd-power` takes a low-level `handle-lid-switch` block inhibitor to manage the lid itself (this is normal — it's how desktop environments "own" the lid). The bug: it **gets stuck holding that inhibitor with a phantom external monitor and never releases it.**

- gsd-power's lid logic keys off `external_monitor_is_connected()`; the inhibitor is taken via `sync_lid_inhibitor()` → `inhibit_lid_switch()`, and is *supposed* to be released by an 8 s safety timer (`LID_CLOSE_SAFETY_TIMEOUT`, `inhibit_lid_switch_timer_cb()` → "no external monitors … uninhibiting lid close").
- That release path fails after certain resume-time display reconfigurations, leaving a **stale** lock. This is a long-standing, **unfixed** gsd-power failure mode (no fixed upstream release found as of GNOME 50; closest report: the Arch GNOME 49/50 lid-inhibitor-latch thread). The `lid-close-suspend-with-external-monitor` gsetting is a known **no-op** upstream — don't rely on it.

### The trigger (forensically pinned)

A **spurious AMD s2idle glitch-wake**. On framework, the stuck lock was acquired in the 30 s after a stray resume at `Jun 25 21:51:47` — kernel logged `Wakeup unrelated to ACPI SCI` / `Triggering wakeup from IRQ 7` (a stray **device IRQ, not a lid-open**; the lid stayed closed and there was no `Lid opened` until the next day). The resume churned KMS on `eDP-1` (`drmModeAtomicCommit: Invalid argument`), gsd-power armed its lid inhibitor on the resulting monitor-change and never let go. **Moonlight and the nightly nixos-upgrade were both ruled out** (the lock pre-dated both; Moonlight had been running since before the suspend; the 01:46 upgrade was only a dbus config reload, no daemon restart).

This is a known **Framework-13-AMD s2idle quirk** (spurious wakes + DMUB HPD connector re-probe on resume; see the Jan 2026 amd-gfx report for this hardware). It will **recur** on glitchy resumes — so the fix must be structural, not a one-off clear.

## The fix

**Take the lid away from GNOME and give it to logind**, via:

```nix
services.upower.ignoreLid = true;   # → IgnoreLid=true in UPower.conf
```

Why this works (authoritative, from `gsd-power-manager.c`, GNOME 50):

```c
manager->lid_is_present = up_client_get_lid_is_present (manager->up_client);   // reads UPower
…
/* set up the screens */
if (manager->lid_is_present) {                                                 // gate
        g_signal_connect_swapped (manager->display_config, "notify::has-external-monitor", …);
        watch_external_monitor ();
        sync_lid_inhibitor (manager);   // ← the ONLY path that takes the handle-lid-switch lock
}
```

`IgnoreLid=true` makes UPower report `LidIsPresent=false` → `lid_is_present=false` → gsd-power **skips this whole block**: it never connects the monitor-change handler, never calls `sync_lid_inhibitor()`, **never takes the lid inhibitor**. logind then drives lid-close natively from the kernel `SW_LID` switch (it reads the lid directly, *not* via UPower) using `HandleLidSwitch=suspend-then-hibernate` from the same module — the path that already works.

This kills the **entire bug class** (any future s2idle/reconfig desync), not just this trigger. Trade-off: GNOME no longer does external-monitor-aware clamshell ("lid closed + external monitor → stay awake"). framework is a roaming, single-panel laptop that doesn't use that, and screen-lock-on-suspend is unaffected (driven by the logind PrepareForSleep signal, not lid handling).

> **Confirmed:** gsd-power's wrapped binary links `libupower-glib.so.3` and reads lid via `UpClient`, so `IgnoreLid` is the correct lever (not a logind-side knob).

## Deploy & verify

`services.upower.ignoreLid` only takes effect when gsd-power **restarts** (it reads `lid_is_present` once at startup), so:

1. Deploy on framework (interactive: `sudo nixos-rebuild switch --flake .#framework`, or nightly).
2. **Reboot** (also clears any currently-stuck lock).
3. Verify — there should be **no** gsd-power lid lock anymore:
   ```sh
   systemd-inhibit --list | grep handle-lid-switch        # → (empty)
   upower -d | grep -i lid                                 # → lid-is-present: no
   ```
4. Close the lid → journal shows `systemd-logind: Lid closed.` → `Suspending, then hibernating…`.

## If it ever recurs (it shouldn't)

If a `gsd-power … handle-lid-switch … block` lock reappears after this fix, then `IgnoreLid` isn't taking effect (check `/etc/UPower/UPower.conf` has `IgnoreLid=true`, and that gsd-power was restarted/relogged since). Stop-gap clear without reboot: `killall gsd-power` (GNOME respawns it and it re-reads `lid_is_present`). Do **not** reach for `LidSwitchIgnoreInhibited` — see the trap at the top.

## History

- 2026-06-26: User reported "framework won't suspend with caffeine on + lid closed."
  - **Caffeine exonerated** — it only holds a GNOME *idle* inhibitor (flag 8); disabling it left the lid lock untouched. Not the cause.
  - First fix attempt scoped `LidSwitchIgnoreInhibited=no` to the nightly-update window — **reverted** after code review proved (against systemd 260 `logind.conf(5)`) that low-level `handle-lid-switch` locks are honored regardless, so it couldn't fix anything.
  - Trigger investigation pinned the cause to the AMD s2idle glitch-wake (above).
  - Landed `services.upower.ignoreLid = true`.
