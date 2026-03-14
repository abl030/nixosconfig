#!/usr/bin/env python3
"""RTRFM Now Playing sensor script for Home Assistant command_line sensor.

Discovers the current RTRFM show via Airnet API, fetches its playlist,
and outputs JSON with the latest track info.

Uses a cache file to avoid re-discovering the current show on every poll.
Show discovery (~2s) happens only when the cache expires. Playlist fetch
(~0.4s) happens every run.

See ha/research/rtrfm-nowplaying.md for full API research.
"""

import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from urllib.request import Request, urlopen
from urllib.error import URLError

API_BASE = "https://airnet.org.au/rest/stations/6RTR"
USER_AGENT = "HomeAssistant-RTRFM/1.0"
CACHE_FILE = "/tmp/rtrfm_show_cache.json"
AWST = timezone(timedelta(hours=8))
MAX_WORKERS = 20
REQUEST_TIMEOUT = 10


def api_get(url):
    """Fetch JSON from Airnet API with required User-Agent header."""
    req = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        return json.loads(resp.read().decode())


def get_active_slugs():
    """Get all active (non-archived) program slugs."""
    programs = api_get(f"{API_BASE}/programs")
    return [
        (p["slug"], p["name"])
        for p in programs
        if not p.get("archived", False) and p.get("slug")
    ]


def parse_airnet_dt(dt_str):
    """Parse Airnet datetime string (AWST, no timezone info) to aware datetime."""
    if not dt_str:
        return None
    # Format: "2026-03-13 17:00:00" (AWST)
    return datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S").replace(tzinfo=AWST)


def fetch_current_episode(slug, name, now):
    """Check if this program has an episode on air right now."""
    try:
        episodes = api_get(f"{API_BASE}/programs/{slug}/episodes")
        for ep in episodes:
            start = parse_airnet_dt(ep.get("start"))
            end = parse_airnet_dt(ep.get("end"))
            if start and end and start <= now <= end:
                return {
                    "slug": slug,
                    "show": name,
                    "start": ep["start"],
                    "end": ep["end"],
                    "playlist_url": ep.get("playlistRestUrl", ""),
                }
    except (URLError, json.JSONDecodeError, KeyError):
        pass
    return None


def discover_current_show(now):
    """Find which show is currently on air by checking all active programs."""
    slugs = get_active_slugs()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {
            pool.submit(fetch_current_episode, slug, name, now): slug
            for slug, name in slugs
        }
        for future in as_completed(futures):
            result = future.result()
            if result:
                return result
    return None


def get_playlist(show_info):
    """Fetch the playlist for a show and return the latest track."""
    url = show_info.get("playlist_url")
    if not url:
        # Build URL from show info
        slug = show_info["slug"]
        start_encoded = show_info["start"].replace(" ", "+").replace(":", "%3A")
        url = f"{API_BASE}/programs/{slug}/episodes/{start_encoded}/playlists"
    try:
        tracks = api_get(url)
        if tracks and isinstance(tracks, list):
            # Last item is most recently logged track
            last = tracks[-1]
            return {
                "artist": last.get("artist", ""),
                "title": last.get("title", ""),
            }
    except (URLError, json.JSONDecodeError, KeyError):
        pass
    return None


def load_cache():
    """Load cached show info if still valid."""
    try:
        with open(CACHE_FILE) as f:
            cache = json.load(f)
        end = parse_airnet_dt(cache.get("end"))
        if end and datetime.now(AWST) <= end:
            return cache
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        pass
    return None


def save_cache(show_info):
    """Cache the current show info."""
    try:
        with open(CACHE_FILE, "w") as f:
            json.dump(show_info, f)
    except OSError:
        pass


def main():
    now = datetime.now(AWST)

    # Try cached show first
    show = load_cache()
    if not show:
        show = discover_current_show(now)
        if show:
            save_cache(show)

    if not show:
        print(json.dumps({
            "state": "RTRFM 92.1",
            "artist": "",
            "title": "",
            "show": "RTRFM 92.1",
        }))
        return

    track = get_playlist(show)
    artist = track["artist"] if track else ""
    title = track["title"] if track else ""

    if artist and title:
        state = f"{artist} - {title}"
    elif artist:
        state = artist
    elif title:
        state = title
    else:
        state = show["show"]

    print(json.dumps({
        "state": state,
        "artist": artist,
        "title": title,
        "show": show["show"],
    }))


if __name__ == "__main__":
    main()
