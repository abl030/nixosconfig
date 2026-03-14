# RTRFM Now Playing - API Research

**Date:** 2026-03-13
**Status:** Research complete
**Goal:** Find the simplest way to get currently playing track (artist + title) from RTRFM for a Home Assistant sensor polling every 2-3 minutes.

## Station Info

- Station ID: `6RTR`
- Name: RTRFM 92.1
- Stream URL: `https://live.rtrfm.com.au/stream1` (SHOUTcast, audio/aacp, 64kbps)
- Airnet API base: `https://airnet.org.au/rest/stations/6RTR`
- Timezone: Australia/Perth (AWST, UTC+8)
- API requires a User-Agent header (returns 403 with Python's default `Python-urllib`)

## API Structure (Airnet)

### Hierarchy

```
Station (6RTR)
  -> Programs (breakfast, drivetime, etc.) -- 59 active, 21 archived
    -> Episodes (one per broadcast, identified by start datetime)
      -> Playlists (array of track objects)
```

### Endpoints

| Endpoint | Returns |
|----------|---------|
| `/rest/stations/6RTR` | Station metadata + links to programs/channels |
| `/rest/stations/6RTR/programs` | Array of all programs (~86) with slug, name, broadcasters, archived flag |
| `/rest/stations/6RTR/programs/{slug}` | Single program detail + `episodesRestUrl` |
| `/rest/stations/6RTR/programs/{slug}/episodes` | Array of recent episodes (last ~2 weeks) |
| `/rest/stations/6RTR/programs/{slug}/episodes/{datetime}` | Single episode detail + `playlistRestUrl` |
| `/rest/stations/6RTR/programs/{slug}/episodes/{datetime}/playlists` | Array of track objects |

Episode datetime format in URL: `YYYY-MM-DD+HH%3AMM%3ASS` (e.g., `2026-03-13+17%3A00%3A00`)

### Endpoints That Don't Exist (404)

- `/rest/stations/6RTR/episodes`
- `/rest/stations/6RTR/nowplaying`
- `/rest/stations/6RTR/current`
- `/rest/stations/6RTR/guides/fm/episodes`

### RTRFM WordPress API

- `/wp-json/rtrfm/v1/show-times/{id}` exists but returned empty
- No now-playing or on-air endpoint found

## Key Findings

### 1. `currentEpisode: true` Does NOT Mean "Currently On Air"

Multiple programs simultaneously have `currentEpisode: true`. At 6pm Friday:
- Breakfast (6-9am) -- `currentEpisode: true`
- Full Frequency (3-5pm) -- `currentEpisode: true`
- Drivetime (5-7pm) -- `currentEpisode: true`
- El Ritmo (Mon 9-11pm, last aired March 10) -- `currentEpisode: true`

**Conclusion:** `currentEpisode` means "most recent episode for this program." NOT usable for "what's on now."

### 2. ICY Stream Metadata is Empty

The SHOUTcast stream supports ICY metadata (`icy-metaint: 16384`) but metadata blocks are consistently zero-length across 10+ blocks. RTRFM does not inject track info into the stream.

### 3. Episodes Are Created When Shows Start (Not in Advance)

At 6:30pm Friday, only 6 episodes existed for the day (4am through 7pm). The 7pm+ evening shows hadn't been created yet. This means you cannot pre-fetch the full day's schedule in advance.

### 4. The "Iterate All Programs" Approach Works

Fetching episodes for all 59 active programs in parallel takes **under 2 seconds**. This is the most reliable way to find what's currently on air:

```python
# Parallel fetch: ~1.8 seconds for all 59 programs
# Sequential fetch: ~14 seconds (too slow)
```

### 5. Track Data Structure

```json
{
  "type": "track",
  "id": 10864679,
  "artist": "QZB x Charli Brix",
  "title": "Overdrive",
  "track": "Overdrive",
  "release": null,
  "time": "06:02:00",
  "approximateTime": "2026-03-13 18:02:00",
  "contentDescriptors": {
    "isAustralian": false, "isLocal": false,
    "isFemale": true, "isGenderNonConforming": false,
    "isIndigenous": false, "isNew": null
  }
}
```

- `artist` and `title` are the key fields
- `approximateTime` may be **null** for recently entered tracks (presenter hasn't set the time)
- `time` field uses 12-hour format without AM/PM context -- unreliable
- Tracks are NOT always in chronological order
- The **last item** in the array is the most recently logged track
- Some shows log tracks; others return `[]`

### 6. API Call Performance

| Operation | Time |
|-----------|------|
| Single playlist fetch | ~0.4s |
| Single episodes fetch | ~0.3s |
| All 59 programs' episodes (parallel, 20 threads) | ~1.8s |
| All 59 programs' episodes (sequential) | ~14s |

### 7. Error Responses

- Future/non-existent episodes: `{"message":"No such episode"}`
- Empty playlist: `[]`
- 403 if no User-Agent header

### 8. Friday Schedule (Observed 2026-03-13)

| Time | Program | Slug |
|------|---------|------|
| 04:00-06:00 | Snooze Button | snoozebutton |
| 06:00-09:00 | Breakfast | breakfast |
| 09:00-12:00 | Artbeat | artbeat |
| 12:00-15:00 | Out To Lunch | otl |
| 15:00-17:00 | Full Frequency | fullfrequency |
| 17:00-19:00 | Drivetime | drivetime |
| 19:00+ | (not yet created at time of research) | ? |

## Recommended Approach

### Strategy: `command_line` Sensor with Python Script

A small Python script that runs every 2-3 minutes via HA's `command_line` sensor platform.

### Algorithm

```
1. Fetch all active program slugs (single API call, cache for 24h)
2. For each slug, fetch episodes (parallel, ~2s total)
3. Find the episode whose start <= now <= end
4. Fetch that episode's playlist
5. Return the last track's artist + title
6. If no show found or playlist empty, return fallback text
```

### Why This Approach

- **No hardcoded schedule needed** -- discovers what's on dynamically
- **2 seconds** for schedule discovery (parallel), then 0.4s for playlist = ~2.5s total
- Polling every 2-3 minutes means ~2.5s of API work per poll is acceptable
- Falls back gracefully when no tracks are logged
- Works for any day of week, any time, including schedule changes

### Optimization: Two-Tier Polling

To reduce API load:
1. **Every 30 minutes:** Re-discover which show is on (iterate all programs)
2. **Every 2 minutes:** Fetch playlist for the known current show

If the show's `end` time passes, trigger a re-discovery.

### Alternative: Hardcoded Schedule

If API reliability is a concern, hardcode the weekly schedule and only fetch playlists. The RTRFM weekday schedule (6am-7pm) is very stable:
- Breakfast, morning show, OTL, afternoon show, Drivetime run every weekday
- Evening/weekend shows vary but can be hardcoded from the program guide
- Update the mapping when the schedule changes (quarterly)

### Output Format

For the HA sensor, return JSON:
```json
{
  "artist": "The Cactus Channel",
  "title": "Storefront",
  "show": "Drivetime",
  "show_slug": "drivetime"
}
```

Use HA template sensors to extract individual attributes.

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Between shows (gap in schedule) | Return show="RTRFM 92.1", no track info |
| Show on but no tracks logged | Return show name, artist/title empty |
| API down | Return cached last-known value |
| Multiple shows overlap | Pick the first match (shouldn't happen) |
| Late-night shows (past midnight) | episode start is previous day -- handle date boundary |
