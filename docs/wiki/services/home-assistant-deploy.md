# Home Assistant — Topology, SSH access, and YAML deploy procedure

**Researched:** 2026-05-25
**Status:** Working — deploy via SSH + tar-pipe, reload via MCP service call.

## Topology

- **`home.ablz.au`** → DNS resolves to `192.168.1.6` (caddy host, Home Manager-only) → Caddy reverse-proxies to `192.168.1.20:8123`.
- **`192.168.1.20`** = Home Assistant Operating System (HAOS). Not in this NixOS repo. Manage via the HA UI + this deploy procedure.
- HAOS version visible via `ha core info`. Add-ons run as Alpine containers; `/config` is bind-mounted into them.

## SSH access

- Port 22 on `192.168.1.20` is exposed by the **Advanced SSH & Web Terminal** community add-on. Port 22222 (official Terminal & SSH add-on) is NOT installed.
- User: `abl030`, UID 1000, in `wheel`. **Passwordless sudo.**
- **Authorized keys** are configured via the SSH add-on's `authorized_keys:` option in the HA UI (Settings → Add-ons → Advanced SSH & Web Terminal → Configuration). On first auth they get installed into `/home/abl030/.ssh/authorized_keys`.
- The master fleet identity (`~/.ssh/id_ed25519` from doc1/proxmox-vm, fingerprint `master-fleet-identity`) is authorized as of 2026-05-25.

### Quick connectivity test

```bash
ssh abl030@192.168.1.20 'id; sudo ls /config | head -5'
```

## File layout

`/config/` on HAOS is the live config root. Files declared in `configuration.yaml`:

- **`homeassistant.packages:`** — eight `!include` package files: `solar_analytics.yaml`, `oral_b_package.yaml`, `energy_tariffs.yaml`, `energy_tarrif_2.yaml`, `energy_tarrif1_battery.yaml`, `energy_tarrif_2_battery.yaml`, `infinite_battery.yaml`, `bedtime.yaml`.
- **Top-level `!include`s**: `automations.yaml`, `scripts.yaml`, `scenes.yaml`.
- **`secrets.yaml`** — sensitive, NOT mirrored to the repo.

All mirrored in `ha/` (root + `ha/energy/`). See `ha/CLAUDE.md` for the table.

## Deploy procedure

### Why not scp?

The Advanced SSH add-on doesn't enable the SFTP subsystem, so plain `scp file remote:` fails with `subsystem request failed on channel 0`. Two options that work:

1. **`scp -O ...`** — legacy mode, bypasses SFTP. Works but less reliable for batches.
2. **tar-over-ssh** — what we use. Single SSH connection, reliable, batches files cleanly.

### Standard deploy (tar-over-ssh)

```bash
# Single file
tar -C ha -cf - bedtime.yaml | \
  ssh abl030@192.168.1.20 'tar -C /tmp -xf - && \
    sudo install -m 644 -o root -g root /tmp/bedtime.yaml /config/bedtime.yaml && \
    rm /tmp/bedtime.yaml && \
    sudo md5sum /config/bedtime.yaml'

# Multiple files
tar -C ha -cf - bedtime.yaml oral_b_package.yaml | \
  ssh abl030@192.168.1.20 'tar -C /tmp -xf - && \
    for f in bedtime.yaml oral_b_package.yaml; do
      sudo install -m 644 -o root -g root /tmp/$f /config/$f && rm /tmp/$f
    done && \
    sudo md5sum /config/bedtime.yaml /config/oral_b_package.yaml'
```

Always **verify md5** afterwards against the repo file:

```bash
md5sum ha/bedtime.yaml
```

### Pre-deploy validation

```bash
# Local YAML syntax
yq '.' ha/bedtime.yaml > /dev/null && echo OK

# On HAOS: full HA config validation (currently broken — needs ha auth)
ssh abl030@192.168.1.20 'sudo ha core check'
#   → "unauthorized: missing or invalid API token"
# Workaround: use the MCP `ha_call_service(domain=homeassistant, service=check_config)`
# which goes through HA's HTTP API and posts result as a persistent_notification.
```

### Reload

| Change | Reload method |
|---|---|
| Template sensors (state-based) | `ha_call_service(homeassistant.reload_all)` |
| Trigger-based template sensors | Same (`reload_all`) |
| Input helpers (number/datetime/boolean) | `reload_all` |
| Automations | `reload_all` |
| **Statistics platform sensors** | **Full restart required** — `ha_call_service(homeassistant.restart)`. `reload_all` does NOT register new statistics platform entities. |
| Dashboard YAML | No restart — `ha_config_set_dashboard(url_path, config)` via MCP (dashboards live in `.storage/`, not in `/config/*.yaml`). |
| New domains / new package files | Full restart |

### Drift check (any time)

```bash
diff <(md5sum ha/*.yaml ha/energy/*.yaml | awk '{print $1, $2}' | sed 's|ha/||;s|energy/||' | sort) \
     <(ssh abl030@192.168.1.20 'sudo md5sum /config/{bedtime,oral_b_package,configuration,automations,scripts,scenes,solar_analytics,energy_tariffs,energy_tarrif_2,energy_tarrif1_battery,energy_tarrif_2_battery,infinite_battery}.yaml' | awk '{print $1, $2}' | sed 's|/config/||' | sort)
```

## Gotchas encountered (worth saving for next session)

### 1. `input_datetime` defaults to "now", not unset
HA initializes a fresh `input_datetime` to the current datetime, not unset. If your accumulator condition is `last_accumulated < yesterday`, the first run skips. **Fix:** add `initial: "1970-01-01"` in the YAML AND manually `input_datetime.set_datetime` for already-created helpers (because `initial:` only applies on first creation, never on subsequent reloads).

### 2. Entity_id slug doesn't follow unique_id
HA generates `entity_id` from the `name:` field's slug, not from `unique_id:`. A `name: "All-Time Avg"` becomes `..._all_time_avg`, while a sibling `input_number` with YAML key `..._alltime` keeps `_alltime`. Pick one form consistently in the friendly name OR accept that the entity_id will differ from the unique_id.

### 3. Statistics platform doesn't read LTS
The statistics platform sensor (`platform: statistics, state_characteristic: mean, max_age:`) builds its sample buffer from the **recorder** (default ~10 days), NOT the long-term statistics DB. After every HA restart the buffer rebuilds from the recorder window. For truly all-time aggregates that survive restarts, use `input_number` accumulators + a nightly automation (pattern in `bedtime.yaml`).

### 4. `homeassistant.restart` via MCP
The MCP `ha_call_service(homeassistant.restart)` works but doesn't return until HA is back up (~30-60s). Poll a known entity afterward to confirm the API is responsive.

### 5. `ha core check` fails without API token
The `ha` CLI on HAOS needs `ha auth` configured before `ha core check` will work. Workaround above (use the MCP `check_config` service call instead).

### 6. Daily utility-meter values must be sampled before midnight
Solar/cost accumulators that read `sensor.daily_*` values must run just before midnight, not just after. The daily utility meters can reset around midnight; a `00:00:xx` automation may append a reset-time partial value or nothing at all. Use a `23:59:xx` trigger and stamp `today`, with an idempotent `last_accumulated < today` guard.

## Cross-references

- Source of truth: `ha/CLAUDE.md` (file inventory + deploy summary)
- Dashboard YAML deploy is separate — see "Dashboard Management" in `ha/CLAUDE.md`.
- `bedtime.yaml` is a worked example of all-time + 30d rolling avg + state_class for LTS — read it before adding similar aggregates elsewhere.
