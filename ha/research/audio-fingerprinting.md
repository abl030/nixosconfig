# Audio Fingerprinting for RTRFM Stream Identification

**Date:** 2026-03-14
**Status:** Research complete
**Goal:** Evaluate audio fingerprinting approaches to identify music from the RTRFM live stream (`https://live.rtrfm.com.au/stream1`), as an alternative/complement to the Airnet playlist API (see `rtrfm-nowplaying.md`).

## Context

The Airnet API gives us what the DJ *logged* as playing. Audio fingerprinting would tell us what's *actually* playing. This is useful when:
- The DJ hasn't logged a track yet (latency between play and log)
- The DJ doesn't log tracks at all (some shows return `[]`)
- We want to confirm the logged track matches what's on air
- We want identification during talk segments or jingles

## Audio Capture (Common to All Approaches)

All methods need a WAV/audio snippet from the stream. ffmpeg handles this reliably:

```bash
ffmpeg -i https://live.rtrfm.com.au/stream1 -t 12 -f wav /tmp/rtrfm_sample.wav -y
```

- Stream is AAC (LC), 48kHz stereo, 64kbps
- 12 seconds is the sweet spot (Shazam needs ~5-10s, AcoustID works better with more)
- Capture takes ~0.6s (stream connects fast)
- ICY metadata is empty -- RTRFM does not inject track info into the stream

**In nixpkgs:** `ffmpeg` (yes, multiple variants)

## Option 1: songrec (Shazam client) -- RECOMMENDED

**What:** Open-source Shazam client in Rust. Sends fingerprints to Shazam's servers. No API key needed.

**In nixpkgs:** Yes -- `songrec` v0.4.3

**CLI usage:**
```bash
# Simple output (artist - title on stdout, or error message)
songrec recognize /tmp/sample.wav

# JSON output (full Shazam response)
songrec recognize --json /tmp/sample.wav

# Raw Shazam API response (includes all metadata)
songrec audio-file-to-recognized-song /tmp/sample.wav
```

**Accepted formats:** MP3, FLAC, WAV, OGG natively. Any format if ffmpeg is installed.

**JSON output structure** (from `audio-file-to-recognized-song`):
```json
{
  "matches": [{"id": "...", "offset": 5.2, "frequencyskew": 0.0}],
  "track": {
    "title": "Song Name",
    "subtitle": "Artist Name",
    "key": "12345",
    "hub": { "actions": [{"uri": "spotify:track:..."}] }
  }
}
```
When no match: `{"matches": [], "tagid": "..."}` (raw) or `Error: No match for this song` (recognize subcommand).

**Practical test results:**
- Two 12-15 second samples from RTRFM both returned "No match"
- This is expected for community radio -- RTRFM plays niche/independent music that may not be in Shazam's database
- Shazam's database has ~70M tracks but skews commercial/mainstream
- Talk segments, jingles, and station IDs will never match

**Rate limits:** Undocumented. Shazam doesn't publish limits for their recognition API. The reverse-engineered protocol has been stable for years. Aggressive polling (every minute) is unlikely to cause issues -- Shazam's mobile app does continuous recognition.

**Pros:**
- Zero setup, no API key, no account
- Single binary in nixpkgs, no Python dependency hell
- Fast (~2s per recognition)
- Returns Spotify/Apple Music links when matched

**Cons:**
- Relies on Shazam's undocumented API (could break, though it's been stable for years)
- Poor coverage for indie/community radio music
- Binary output parsing needed for non-JSON mode

**Verdict:** Best option for zero-config deployment. Will identify mainstream tracks reliably. Won't help with RTRFM's more obscure selections.

## Option 2: shazamio (Python Shazam library)

**What:** Async Python library using the same reverse-engineered Shazam API as songrec, but in Python.

**In nixpkgs:** Yes -- `python313Packages.shazamio` v0.8.1, BUT marked as **broken** (build patch fails against current version).

**Workaround:** pip install in a venv works with Python 3.12 (Python 3.13 removed `audioop` module which pydub needs). Requires `LD_LIBRARY_PATH` for numpy's libstdc++ on NixOS.

**Usage:**
```python
import asyncio
from shazamio import Shazam

async def recognize():
    shazam = Shazam()
    result = await shazam.recognize('/tmp/sample.wav')
    if result.get('track'):
        return {
            'title': result['track']['title'],
            'artist': result['track']['subtitle']
        }
    return None
```

**Practical test:** Same no-match results as songrec (uses identical Shazam backend).

**Pros:**
- Native Python async -- integrates cleanly into a Python HTTP server
- No API key needed
- Same recognition quality as songrec

**Cons:**
- **Broken in nixpkgs** -- needs manual packaging or pip venv workaround
- Python 3.13 incompatible (audioop removal)
- More dependencies (numpy, pydub, aiohttp, pydantic)
- Same Shazam coverage limitations as songrec

**Verdict:** If you're already building a Python service and can manage the packaging, this integrates more naturally than shelling out to songrec. But the broken nixpkgs status and Python version constraints make songrec the safer choice. The practical difference is nil -- they hit the same API.

## Option 3: Chromaprint + AcoustID -- NOT RECOMMENDED for radio

**What:** Open-source audio fingerprinting (Chromaprint generates fingerprints, AcoustID database does lookup). Primarily designed for identifying music files in your library, not live radio.

**In nixpkgs:** Yes -- `chromaprint` v1.6.0 (provides `fpcalc`), `python313Packages.pyacoustid`

**Usage flow:**
```bash
# 1. Generate fingerprint
fpcalc -json /tmp/sample.wav
# Returns: {"duration": 12.00, "fingerprint": "AQAA..."}

# 2. Lookup via AcoustID API (requires free API key)
curl "https://api.acoustid.org/v2/lookup?client=YOUR_KEY&duration=12&fingerprint=AQAA...&meta=recordings"
```

**API key:** Required (free registration at acoustid.org via MusicBrainz login).

**Rate limit:** Max 3 requests/second.

**Critical limitation for radio:** AcoustID matches fingerprints against its database of known recordings. The database is built from user submissions of their music libraries. Coverage is heavily biased toward:
- Music available on CD/digital download
- Popular enough that someone submitted it
- Matched to MusicBrainz metadata

For community radio playing unreleased local artists, coverage will be significantly worse than Shazam.

**Additionally:** AcoustID is designed for clean recordings, not radio streams with:
- DJ talk over intros/outros
- Compression artifacts
- Station jingles mixed in
- Crossfading between tracks

**Pros:**
- Fully open source (both fingerprinting and database)
- Free API key, generous rate limits
- MusicBrainz integration gives rich metadata

**Cons:**
- API key required (free but needs registration)
- Much smaller database than Shazam (~35M tracks vs ~70M)
- Designed for clean file matching, not noisy radio streams
- Two-step process (fingerprint then lookup)
- Worst match rate of all options for indie/community radio

**Verdict:** Not suitable for live radio identification. AcoustID excels at "what album is this MP3 from?" not "what's playing on community radio right now?"

## Option 4: AudD -- PAID, NOT RECOMMENDED

**What:** Commercial music recognition API with large database (80M tracks).

**Pricing:**
- Free tier: 300 requests total (not per month -- ever)
- Paid: $5 per 1000 requests
- Stream monitoring: $45/stream/month (their servers listen 24/7)

**API:**
```bash
curl -X POST "https://api.audd.io/" \
  -F "api_token=YOUR_TOKEN" \
  -F "file=@/tmp/sample.wav" \
  -F "return=spotify,apple_music"
```

**Stream monitoring mode:** AudD can continuously monitor the RTRFM stream and call a webhook with identified tracks. At $45/month this is expensive for a hobby project.

**Pros:**
- Large database, good accuracy
- Stream monitoring mode (they do the capture)
- Returns Spotify/Apple Music links

**Cons:**
- 300 free requests is useless for continuous monitoring (exhausted in ~10 hours at 2-min polling)
- Ongoing cost ($45/month stream or ~$200/month for per-request at 2-min polling)
- API key required

**Verdict:** Not viable without paying. The free tier is for testing only.

## Option 5: ACRCloud -- PAID, NOT RECOMMENDED

**What:** Professional audio recognition platform. 14-day free trial, then paid.

**Pricing:** Not publicly listed. Enterprise-oriented. Free trial requires signup.

**Pros:**
- High accuracy
- Broadcast monitoring features
- Huge database

**Cons:**
- Trial-only free access
- Enterprise pricing (likely $100+/month)
- Overkill for a hobby project

**Verdict:** Not viable for free use.

## Practical Test Results (2026-03-14 ~16:00 AWST)

| Tool | Sample 1 (12s) | Sample 2 (15s) |
|------|----------------|----------------|
| songrec | No match | No match |
| shazamio | No match (`retryms: 12000`) | (not retested, same backend) |
| fpcalc | Generated fingerprint OK | Generated fingerprint OK |

Both samples were captured during "Drastic On Plastic" (3-5pm Friday) which plays alternative/indie music. The no-match results highlight the fundamental challenge: community radio plays music that's often not in commercial recognition databases.

## Recommendation

### For RTRFM specifically: Combine Airnet API + songrec fallback

The Airnet playlist API (documented in `rtrfm-nowplaying.md`) is the **primary** data source. It returns exactly what the DJ logged. Audio fingerprinting serves as a secondary source for when the API has no data.

**Architecture:**
```
1. Check Airnet API for current show's playlist (2.5s)
   -> If track found with recent timestamp, use it
   -> If no tracks logged or playlist empty, fall through

2. Capture 12s of audio, run songrec (total ~3s)
   -> If match found, use it
   -> If no match, return "Unknown track" or show name only
```

**Why this order:**
- Airnet API is faster (2.5s vs 3s for capture+fingerprint)
- Airnet works for ALL music (not just what's in Shazam's DB)
- songrec fills the gap when DJs haven't logged tracks yet
- songrec needs no API key or account

### For a generic radio stream: songrec alone

If applying this to commercial radio (Triple J, commercial FM), songrec alone would work well -- those stations play mainstream music that Shazam recognizes easily.

### NixOS service dependencies

```nix
{
  environment.systemPackages = with pkgs; [
    songrec       # Audio recognition
    ffmpeg        # Stream capture
    chromaprint   # Optional: AcoustID fingerprinting
  ];
}
```

Or for a Python service with subprocess calls:
```nix
{
  # In a buildPythonApplication or similar
  propagatedBuildInputs = [ pkgs.ffmpeg pkgs.songrec ];
}
```

### Expected match rates for RTRFM

Based on the station's programming:
- **Mainstream tracks** (occasionally played): ~80% match rate
- **Australian indie**: ~30-50% match rate
- **Local/unsigned artists**: ~5-10% match rate
- **Talk segments/jingles**: 0% (by design)
- **DJ sets/mixes**: ~20-40% (recognizes source tracks if unmixed)

The Airnet API will always be the more reliable source for RTRFM. Audio fingerprinting is a nice supplement, not a replacement.
