"""RTRFM Now Playing HTTP API server.

Captures audio from the RTRFM live stream every 30 seconds, fingerprints
it via songrec (Shazam), and serves the current track as JSON.

Endpoints:
  GET /           → JSON: {artist, title, state, source}
  GET /health     → JSON: {status: "ok"}

Only updates the displayed track when a new match is found. When there's
no match (talking, interviews, obscure tracks), the last known track
is retained.
"""

import json
import logging
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

STREAM_URL = "https://live.rtrfm.com.au/stream1"
CAPTURE_SECONDS = 15
POLL_INTERVAL = 30  # seconds between fingerprint attempts

log = logging.getLogger("rtrfm")


class NowPlaying:
    """Thread-safe store for the current track."""

    def __init__(self):
        self._lock = threading.Lock()
        self._track = {
            "state": "RTRFM 92.1",
            "artist": "",
            "title": "",
            "source": "startup",
        }

    def get(self):
        with self._lock:
            return dict(self._track)

    def update(self, artist, title):
        with self._lock:
            if artist == self._track["artist"] and title == self._track["title"]:
                return False  # no change
            self._track = {
                "state": f"{artist} \u2014 {title}" if artist and title else artist or title,
                "artist": artist,
                "title": title,
                "source": "shazam",
            }
            return True


now_playing = NowPlaying()


def fingerprint():
    """Capture audio from stream and identify via songrec."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name

    try:
        # Capture audio: mono 16kHz WAV (Shazam's native format)
        result = subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", STREAM_URL,
                "-t", str(CAPTURE_SECONDS),
                "-ac", "1",
                "-ar", "16000",
                "-f", "wav",
                wav_path,
            ],
            capture_output=True,
            timeout=CAPTURE_SECONDS + 15,
        )
        if result.returncode != 0:
            log.warning("ffmpeg capture failed: %s", result.stderr[-200:].decode(errors="replace"))
            return None

        # Fingerprint with songrec
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
            log.debug("No match from Shazam")
            return None

        artist = track.get("subtitle", "")
        title = track.get("title", "")
        log.info("Shazam match: %s - %s", artist, title)
        return {"artist": artist, "title": title}

    except subprocess.TimeoutExpired:
        log.warning("Fingerprint timed out")
        return None
    except (json.JSONDecodeError, KeyError) as e:
        log.warning("Error parsing songrec output: %s", e)
        return None
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass


def poll_loop():
    """Background thread: capture and fingerprint every POLL_INTERVAL seconds."""
    log.info("Poll loop started (every %ds, %ds capture)", POLL_INTERVAL, CAPTURE_SECONDS)
    while True:
        try:
            match = fingerprint()
            if match:
                changed = now_playing.update(match["artist"], match["title"])
                if changed:
                    log.info("Track changed: %s - %s", match["artist"], match["title"])
            else:
                log.debug("No match, keeping current track")
        except Exception:
            log.exception("Error in poll loop")
        time.sleep(POLL_INTERVAL)


class Handler(BaseHTTPRequestHandler):
    """HTTP request handler."""

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        elif self.path in ("/", "/now-playing"):
            self._respond(200, now_playing.get())
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

    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    # Start background fingerprint loop
    poller = threading.Thread(target=poll_loop, daemon=True)
    poller.start()

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
