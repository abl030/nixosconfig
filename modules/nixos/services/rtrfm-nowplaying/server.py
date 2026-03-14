"""RTRFM Now Playing HTTP API server.

Discovers the current RTRFM show via Airnet API, fetches its playlist,
and serves JSON with the latest track info.

Endpoints:
  GET /           → JSON: {artist, title, show, state}
  GET /health     → JSON: {status: "ok"}

Caching:
  - Show discovery (all 59 programs): cached for 30 minutes
  - Playlist fetch: cached for 90 seconds

See ha/research/rtrfm-nowplaying.md for full API research.
"""

import json
import logging
import signal
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import URLError

API_BASE = "https://airnet.org.au/rest/stations/6RTR"
USER_AGENT = "HomeAssistant-RTRFM/1.0"
AWST = timezone(timedelta(hours=8))
MAX_WORKERS = 20
REQUEST_TIMEOUT = 10
SHOW_CACHE_TTL = 1800  # 30 minutes
PLAYLIST_CACHE_TTL = 90  # 90 seconds

log = logging.getLogger("rtrfm")


class Cache:
    """Thread-safe cache with TTL."""

    def __init__(self):
        self._lock = threading.Lock()
        self._show = None
        self._show_expires = 0
        self._playlist = None
        self._playlist_expires = 0

    def get_show(self):
        with self._lock:
            if time.monotonic() < self._show_expires:
                return self._show
            return None

    def set_show(self, show):
        with self._lock:
            self._show = show
            self._show_expires = time.monotonic() + SHOW_CACHE_TTL

    def invalidate_show(self):
        with self._lock:
            self._show = None
            self._show_expires = 0

    def get_playlist(self):
        with self._lock:
            if time.monotonic() < self._playlist_expires:
                return self._playlist
            return None

    def set_playlist(self, playlist):
        with self._lock:
            self._playlist = playlist
            self._playlist_expires = time.monotonic() + PLAYLIST_CACHE_TTL


cache = Cache()


def api_get(url):
    """Fetch JSON from Airnet API with required User-Agent header."""
    req = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        return json.loads(resp.read().decode())


def get_active_slugs():
    """Get all active (non-archived) program slugs."""
    log.debug("Fetching program list from Airnet")
    programs = api_get(f"{API_BASE}/programs")
    slugs = [
        (p["slug"], p["name"])
        for p in programs
        if not p.get("archived", False) and p.get("slug")
    ]
    log.debug("Found %d active programs", len(slugs))
    return slugs


def parse_airnet_dt(dt_str):
    """Parse Airnet datetime string (AWST, no timezone info) to aware datetime."""
    if not dt_str:
        return None
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
    except (URLError, json.JSONDecodeError, KeyError) as e:
        log.debug("Error checking program %s: %s", slug, e)
    return None


def discover_current_show(now):
    """Find which show is currently on air by checking all active programs."""
    log.info("Discovering current show (checking all programs)")
    slugs = get_active_slugs()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {
            pool.submit(fetch_current_episode, slug, name, now): slug
            for slug, name in slugs
        }
        for future in as_completed(futures):
            result = future.result()
            if result:
                log.info(
                    "Current show: %s (%s – %s)",
                    result["show"],
                    result["start"],
                    result["end"],
                )
                return result
    log.warning("No show currently on air")
    return None


def get_playlist(show_info):
    """Fetch the playlist for a show and return the latest track."""
    url = show_info.get("playlist_url")
    if not url:
        slug = show_info["slug"]
        start_encoded = show_info["start"].replace(" ", "+").replace(":", "%3A")
        url = f"{API_BASE}/programs/{slug}/episodes/{start_encoded}/playlists"
    try:
        tracks = api_get(url)
        if tracks and isinstance(tracks, list):
            last = tracks[-1]
            artist = last.get("artist", "")
            title = last.get("title", "")
            log.debug("Latest track: %s - %s", artist, title)
            return {"artist": artist, "title": title}
    except (URLError, json.JSONDecodeError, KeyError) as e:
        log.warning("Error fetching playlist for %s: %s", show_info["show"], e)
    return None


def get_now_playing():
    """Get the current now-playing info. Uses caching to minimise API calls."""
    now = datetime.now(AWST)

    # Check if cached show is still valid (within its broadcast window)
    show = cache.get_show()
    if show:
        end = parse_airnet_dt(show.get("end"))
        if end and now > end:
            log.info("Cached show %s has ended, re-discovering", show["show"])
            cache.invalidate_show()
            show = None

    if not show:
        show = discover_current_show(now)
        if show:
            cache.set_show(show)

    if not show:
        return {
            "state": "RTRFM 92.1",
            "artist": "",
            "title": "",
            "show": "RTRFM 92.1",
        }

    # Check playlist cache
    playlist = cache.get_playlist()
    if not playlist:
        playlist = get_playlist(show)
        if playlist:
            cache.set_playlist(playlist)

    artist = playlist["artist"] if playlist else ""
    title = playlist["title"] if playlist else ""

    if artist and title:
        state = f"{artist} - {title}"
    elif artist:
        state = artist
    elif title:
        state = title
    else:
        state = show["show"]

    return {
        "state": state,
        "artist": artist,
        "title": title,
        "show": show["show"],
    }


class Handler(BaseHTTPRequestHandler):
    """HTTP request handler for the now-playing API."""

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        elif self.path in ("/", "/now-playing"):
            try:
                data = get_now_playing()
                self._respond(200, data)
            except Exception as e:
                log.exception("Error getting now-playing data")
                self._respond(500, {"error": str(e)})
        else:
            self._respond(404, {"error": "not found"})

    def _respond(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        # Route HTTP access logs through Python logging
        log.info(format, *args)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8095

    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    server = HTTPServer(("127.0.0.1", port), Handler)
    log.info("RTRFM Now Playing server starting on port %d", port)

    def shutdown(signum, _frame):
        log.info("Shutting down (signal %d)", signum)
        threading.Thread(target=server.shutdown).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        log.info("Server stopped")


if __name__ == "__main__":
    main()
