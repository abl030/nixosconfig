"""RTRFM Now Playing HTTP API server.

Captures audio from the RTRFM live stream every 30 seconds, fingerprints
it via songrec (Shazam), and serves the current track as JSON. Also
discovers the current show name via Airnet API.

Endpoints:
  GET /              → JSON: {artist, title, show, state, source, last_updated}
  GET /now-playing   → same as /
  GET /tracklist     → current show's tracks
  GET /tracklist?date=2026-03-14          → all shows/tracks for that date
  GET /tracklist?show=The+Rounds          → specific show (all time)
  GET /tracklist?show=The+Rounds&date=2026-03-14 → specific show on date
  GET /shows         → list all show names with tracklist data
  GET /health        → JSON: {status: "ok"}

Tracklists are persisted to STATE_DIR as JSONL files (one per show).
"""

import json
import logging
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from urllib.request import Request, urlopen
from urllib.error import URLError

STREAM_URL = "https://live.rtrfm.com.au/stream1"
CAPTURE_SECONDS = 15
POLL_INTERVAL = 30  # seconds between fingerprint attempts

# Airnet show discovery
API_BASE = "https://airnet.org.au/rest/stations/6RTR"
USER_AGENT = "HomeAssistant-RTRFM/1.0"
AWST = timezone(timedelta(hours=8))
SHOW_POLL_INTERVAL = 1800  # 30 minutes
MAX_WORKERS = 20
REQUEST_TIMEOUT = 10

log = logging.getLogger("rtrfm")


# -- Airnet show discovery (name only, not tracks) --

def api_get(url):
    req = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        return json.loads(resp.read().decode())


def parse_airnet_dt(dt_str):
    if not dt_str:
        return None
    return datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S").replace(tzinfo=AWST)


def fetch_current_episode(slug, name, now):
    try:
        episodes = api_get(f"{API_BASE}/programs/{slug}/episodes")
        for ep in episodes:
            start = parse_airnet_dt(ep.get("start"))
            end = parse_airnet_dt(ep.get("end"))
            if start and end and start <= now <= end:
                return {"slug": slug, "show": name, "end": ep["end"]}
    except (URLError, json.JSONDecodeError, KeyError):
        pass
    return None


def discover_current_show():
    now = datetime.now(AWST)
    log.info("Discovering current show via Airnet")
    try:
        programs = api_get(f"{API_BASE}/programs")
    except (URLError, json.JSONDecodeError) as e:
        log.warning("Failed to fetch program list: %s", e)
        return None

    slugs = [
        (p["slug"], p["name"])
        for p in programs
        if not p.get("archived", False) and p.get("slug")
    ]

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {
            pool.submit(fetch_current_episode, slug, name, now): slug
            for slug, name in slugs
        }
        for future in as_completed(futures):
            result = future.result()
            if result:
                log.info("Current show: %s", result["show"])
                return result
    log.warning("No show currently on air")
    return None


# -- Tracklist persistence --

class TracklistStore:
    """Append-only JSONL tracklists per show, persisted to disk."""

    def __init__(self, state_dir):
        self._dir = pathlib.Path(state_dir) / "tracklists"
        self._dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def _path_for(self, show_name):
        safe = "".join(c if c.isalnum() or c in " -_" else "_" for c in show_name).strip()
        return self._dir / f"{safe}.jsonl"

    def append(self, show_name, artist, title):
        path = self._path_for(show_name)
        with self._lock:
            # Deduplicate: skip if same as last entry
            if path.exists():
                lines = path.read_text().strip().splitlines()
                if lines:
                    try:
                        last = json.loads(lines[-1])
                        if last.get("artist") == artist and last.get("title") == title:
                            log.debug("Skipping duplicate: %s - %s", artist, title)
                            return
                    except json.JSONDecodeError:
                        pass
            entry = {
                "artist": artist,
                "title": title,
                "time": datetime.now(AWST).isoformat(),
            }
            with open(path, "a") as f:
                f.write(json.dumps(entry) + "\n")
        log.info("Tracklist appended: %s - %s [%s]", artist, title, show_name)

    def get(self, show_name, date_filter=None):
        path = self._path_for(show_name)
        if not path.exists():
            return []
        with self._lock:
            lines = path.read_text().strip().splitlines()
        tracks = []
        for line in lines:
            try:
                track = json.loads(line)
                if date_filter and not track.get("time", "").startswith(date_filter):
                    continue
                tracks.append(track)
            except json.JSONDecodeError:
                continue
        return tracks

    def list_shows(self):
        """Return all show names that have tracklist files."""
        shows = []
        with self._lock:
            for path in sorted(self._dir.glob("*.jsonl")):
                shows.append(path.stem)
        return shows

    def get_all_by_date(self, date_filter):
        """Return all tracks across all shows for a given date."""
        results = []
        for show in self.list_shows():
            tracks = self.get(show, date_filter=date_filter)
            if tracks:
                results.append({"show": show, "tracks": tracks})
        return results


# -- Now playing state --

class NowPlaying:
    """Thread-safe store for current track + show."""

    def __init__(self):
        self._lock = threading.Lock()
        self._artist = ""
        self._title = ""
        self._show = "RTRFM 92.1"
        self._show_end = None
        self._last_updated = None
        self._source = "startup"

    def get(self):
        with self._lock:
            artist = self._artist
            title = self._title
            if artist and title:
                state = f"{artist} \u2014 {title}"
            elif artist:
                state = artist
            elif title:
                state = title
            else:
                state = self._show
            return {
                "state": state,
                "artist": artist,
                "title": title,
                "show": self._show,
                "source": self._source,
                "last_updated": self._last_updated,
            }

    def update_track(self, artist, title):
        with self._lock:
            if artist == self._artist and title == self._title:
                return False
            self._artist = artist
            self._title = title
            self._source = "shazam"
            self._last_updated = datetime.now(AWST).isoformat()
            return True

    def update_show(self, show_name, show_end):
        with self._lock:
            self._show = show_name
            self._show_end = show_end

    def get_show(self):
        with self._lock:
            return self._show

    def get_show_end(self):
        with self._lock:
            return self._show_end


now_playing = NowPlaying()
tracklist_store = None  # initialized in main()


# -- Fingerprinting --

def fingerprint():
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name
    try:
        result = subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", STREAM_URL,
                "-t", str(CAPTURE_SECONDS),
                "-ac", "1", "-ar", "16000",
                "-f", "wav", wav_path,
            ],
            capture_output=True,
            timeout=CAPTURE_SECONDS + 15,
        )
        if result.returncode != 0:
            log.warning("ffmpeg failed: %s", result.stderr[-200:].decode(errors="replace"))
            return None

        result = subprocess.run(
            ["songrec", "audio-file-to-recognized-song", wav_path],
            capture_output=True,
            timeout=30,
        )
        if result.returncode != 0:
            log.warning("songrec failed: %s", result.stderr[-200:].decode(errors="replace"))
            return None

        data = json.loads(result.stdout)
        track = data.get("track")
        if not track:
            log.debug("No Shazam match")
            return None

        artist = track.get("subtitle", "")
        title = track.get("title", "")
        log.info("Shazam match: %s - %s", artist, title)
        return {"artist": artist, "title": title}

    except subprocess.TimeoutExpired:
        log.warning("Fingerprint timed out")
        return None
    except (json.JSONDecodeError, KeyError) as e:
        log.warning("songrec parse error: %s", e)
        return None
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass


# -- Background threads --

def fingerprint_loop():
    log.info("Fingerprint loop started (every %ds, %ds capture)", POLL_INTERVAL, CAPTURE_SECONDS)
    while True:
        try:
            match = fingerprint()
            if match:
                changed = now_playing.update_track(match["artist"], match["title"])
                if changed:
                    log.info("Track changed: %s - %s", match["artist"], match["title"])
                    show = now_playing.get_show()
                    tracklist_store.append(show, match["artist"], match["title"])
            else:
                log.debug("No match, keeping current track")
        except Exception:
            log.exception("Error in fingerprint loop")
        time.sleep(POLL_INTERVAL)


def show_discovery_loop():
    log.info("Show discovery loop started (every %ds)", SHOW_POLL_INTERVAL)
    while True:
        try:
            # Check if current show has ended
            end_str = now_playing.get_show_end()
            if end_str:
                end = parse_airnet_dt(end_str)
                if end and datetime.now(AWST) <= end:
                    time.sleep(SHOW_POLL_INTERVAL)
                    continue

            show = discover_current_show()
            if show:
                now_playing.update_show(show["show"], show.get("end"))
        except Exception:
            log.exception("Error in show discovery loop")
        time.sleep(SHOW_POLL_INTERVAL)


# -- HTTP server --

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/health":
            self._respond(200, {"status": "ok"})
        elif path in ("/", "/now-playing"):
            self._respond(200, now_playing.get())
        elif path == "/tracklist":
            date = params.get("date", [None])[0]
            show = params.get("show", [None])[0]
            if date and not show:
                # All shows for a date
                results = tracklist_store.get_all_by_date(date)
                self._respond(200, {"date": date, "shows": results})
            else:
                # Specific show (or current show if not specified)
                show = show or now_playing.get_show()
                tracks = tracklist_store.get(show, date_filter=date)
                resp = {"show": show, "tracks": tracks}
                if date:
                    resp["date"] = date
                self._respond(200, resp)
        elif path == "/shows":
            self._respond(200, {"shows": tracklist_store.list_shows()})
        else:
            self._respond(404, {"error": "not found"})

    def do_OPTIONS(self):
        self._respond(204, None)

    def _respond(self, status, data):
        body = json.dumps(data).encode() if data is not None else b""
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        if data is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        log.info(format, *args)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8095
    state_dir = sys.argv[2] if len(sys.argv) > 2 else "/var/lib/rtrfm-nowplaying"

    global tracklist_store
    tracklist_store = TracklistStore(state_dir)

    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    # Background threads
    threading.Thread(target=fingerprint_loop, daemon=True).start()
    threading.Thread(target=show_discovery_loop, daemon=True).start()

    server = HTTPServer(("127.0.0.1", port), Handler)
    log.info("RTRFM Now Playing server starting on port %d (state: %s)", port, state_dir)

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
