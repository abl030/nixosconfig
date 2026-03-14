# Amp Casting Automations

**Date:** 2026-03-14
**Status:** Working (updated)

## What It Does

Controls the kitchen amplifier via IR blaster (Zigbee2MQTT) based on Chromecast state changes. When audio starts playing on the kitchen Cast group, the amp turns on. When playback stops, it turns off.

## Hardware

- **Amp**: Kitchen amplifier controlled via IR
- **IR Blaster**: Zigbee device `IR_Blaster` via Z2M, MQTT topic `zigbee2mqtt/IR_Blaster/set`
- **Cast devices**: `media_player.kitchen` (group), `media_player.andys_cast` (Chromecast Audio, device_id `ef8802614fd6ee89f80de00dbb81e1ee`)

## IR Codes

| Action | Payload |
|--------|---------|
| Amp ON | `A4YDGwPAAwMAB4YD4AEBA0cRhgNAAYAVgAXgCwFAGQ///4YDhgOGA4YDhgOGAxsD` |
| Amp OFF | `BYADgAP9BkABAYAD4AEBA0sRgANAAYAVgAXgBwEL/Qb9Bv//gAOAA/0GQAEBgAPgAQHgXD8CBv0G` |

## Automations

### Amp ON

| Automation | Trigger | Mode |
|------------|---------|------|
| `Amp_Casting_On` | kitchen or andys_cast → `playing` | restart |
| `Amp_Casting_TurnedOn` | kitchen or andys_cast → `on` | restart |

### Amp OFF

| Automation | Trigger | Mode |
|------------|---------|------|
| `Amp_Casting_TurnOFF` | kitchen or andys_cast → `off` for 3s | restart |
| `Amp_Casting_PauseOff` | kitchen or andys_cast → `paused` for 3s | restart |
| `Amp_Casting_IdleOFF` | kitchen or andys_cast → `idle` for 3s | restart |

All OFF automations also have a condition: neither `media_player.kitchen` nor `media_player.andys_cast` is `playing`.

## Changes Made (2026-03-14)

### Problem

Hitting the RTRFM play button on the dashboard sent `play_media` to `media_player.kitchen` (group), but the amp didn't turn on. Pausing then playing again would work.

### Root Cause

1. **Wrong trigger entity**: All automations used `device_id` triggers watching only `media_player.andys_cast`. The dashboard button targets `media_player.kitchen` (group), which has a different device_id.
2. **Race condition**: When the group starts playing, entities transition through intermediate states (`idle` → `playing`) milliseconds apart. The `idle` OFF automation fired and sent amp OFF *before* the `playing` ON automation could fire. The ON automation then failed with `failed_single` (mode:single blocked it).

### Fix

1. **Switched from `device_id` to `entity_id` state triggers** (HA best practice — device_id breaks on re-add)
2. **Added both entities** to all triggers: `media_player.kitchen` AND `media_player.andys_cast`
3. **Changed ON automations to `mode: restart`** — can't be blocked by a previous run
4. **Added `for: 3 seconds`** to all OFF triggers — gives the `playing` state time to arrive before turning off
5. **Added condition** to OFF automations: don't turn off if either entity is still `playing`

### Previous Configuration (for rollback)

All 5 automations previously used this pattern:
```yaml
trigger:
  - platform: device
    device_id: ef8802614fd6ee89f80de00dbb81e1ee
    domain: media_player
    entity_id: ffd5eb2dc5d44b54c0316e0bacd560c1  # media_player.andys_cast internal UUID
    type: playing  # (or turned_off, paused, idle, turned_on)
condition: []
mode: single
```

To revert, restore the `device` trigger platform with the device_id/entity_id above and remove the `for` and `condition` blocks.
