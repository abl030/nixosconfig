# RTRFM Now Playing Service

**Date researched:** 2026-03-14
**Status:** Working
**Host:** doc2
**URL:** https://rtrfm.ablz.au

## What It Does

REST API that identifies the currently playing track on RTRFM 92.1 community radio using live audio fingerprinting (Shazam via songrec).

## Architecture

```
RTRFM Stream (AAC/MP3)
  → ffmpeg captures 15s mono 16kHz WAV every 30s
  → songrec fingerprints via Shazam API
  → Python HTTP server serves JSON
  → nginx reverse proxy (rtrfm.ablz.au)
  → HA custom dashboard card fetches from browser
```

### Key Components

| Component | Path |
|-----------|------|
| NixOS module | `modules/nixos/services/rtrfm-nowplaying/default.nix` |
| Python server | `modules/nixos/services/rtrfm-nowplaying/server.py` |
| HA dashboard card | Inline JS resource (registered via `ha_config_set_inline_dashboard_resource`) |
| API research | `ha/research/rtrfm-nowplaying.md` |
| Audio fingerprinting research | `ha/research/audio-fingerprinting.md` |

### API Endpoints

| Endpoint | Response |
|----------|----------|
| `GET /` or `/now-playing` | `{"state": "Artist — Title", "artist": "...", "title": "...", "show": "...", "source": "shazam", "last_updated": "ISO8601"}` |
| `GET /tracklist` | Current show's full track history |
| `GET /tracklist?date=2026-03-14` | All shows and their tracks for a given date |
| `GET /tracklist?show=The+Rounds` | Specific show's full track history (all time) |
| `GET /tracklist?show=The+Rounds&date=2026-03-14` | Specific show on a specific date |
| `GET /shows` | List all show names that have tracklist data |
| `GET /health` | `{"status": "ok"}` |

### Tracklist Storage

- Persisted to `/var/lib/rtrfm-nowplaying/tracklists/` (systemd `StateDirectory`)
- One JSONL file per show (e.g., `The Rounds.jsonl`)
- Each line: `{"artist": "...", "title": "...", "time": "ISO8601+08:00"}`
- Survives service restarts. Manual cleanup: delete individual `.jsonl` files via `sudo` on doc2
- Date filtering works by matching the ISO8601 date prefix in the `time` field

### Infrastructure Wiring

- **nginx**: Auto-configured via `homelab.localProxy.hosts`
- **ACME cert**: Cloudflare DNS validation, auto-renewed
- **Uptime Kuma**: Auto-registered monitor on `/health`
- **Gotify**: Failure notification via `OnFailure=` systemd unit
- **Systemd hardening**: DynamicUser, ProtectSystem=strict, PrivateTmp, etc.

## Design Decisions

### Why Shazam over Airnet API?

We initially built this using the Airnet playlist API (presenters manually log tracks). Problems:
- Track data lagged 5-20+ minutes behind live playback
- Some presenters don't log tracks at all
- No "what's playing now" endpoint — required iterating all 59 programs to find the current show

Shazam fingerprinting is near-real-time (30s poll cycle) and works regardless of presenter logging.

### Why songrec?

- In nixpkgs, zero setup
- Uses Shazam's reverse-engineered API — no API key needed
- Single binary, fast execution
- The critical trick: **mono 16kHz WAV** (`-ac 1 -ar 16000`) is Shazam's native format. Default sample rates produce worse matches.

### Limitations

- **No match during talk/interviews** — retains last known track (by design)
- **Very obscure tracks** may not be in Shazam's database (community radio plays niche music)
- **30s poll cycle** means up to ~45s delay (15s capture + 30s interval) on track changes

### HA Dashboard Card

The custom card (`rtrfm-now-playing-card`) is registered as an inline JS resource via the HA MCP. It fetches directly from `rtrfm.ablz.au` in the browser, so:
- Works on the web UI (local network)
- Does NOT work on the HA mobile app (can't resolve internal DNS)
- To fix mobile: either expose via Cloudflare tunnel or switch to an HA REST sensor (requires YAML config access)

## Debugging

```bash
# Check service status
ssh doc2 "systemctl status rtrfm-nowplaying.service"

# Watch live fingerprinting
ssh doc2 "journalctl -u rtrfm-nowplaying.service -f"

# Test endpoint
curl -sk https://rtrfm.ablz.au/now-playing

# Manual fingerprint test
nix-shell -p ffmpeg songrec --run '
  ffmpeg -i https://live.rtrfm.com.au/stream1 -t 15 -ac 1 -ar 16000 -f wav /tmp/test.wav -y 2>/dev/null
  songrec audio-file-to-recognized-song /tmp/test.wav
'
```

## When to Revisit

- If Shazam blocks the reverse-engineered API, consider AudD ($5/1000 requests) or ACRCloud
- If HA gains native REST sensor creation via API, switch the dashboard card to use an entity
- Airnet API research is preserved in `ha/research/rtrfm-nowplaying.md` as a fallback option
