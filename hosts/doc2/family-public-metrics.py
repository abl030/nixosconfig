"""Cloudflare edge traffic for family.barrett-lennard.com as Prometheus counters.

Polls the zone's httpRequestsAdaptiveGroups (GraphQL analytics, available on
the Free plan) in closed five-minute windows and adds each window into
cumulative counters, kept in STATE_DIRECTORY so they survive restarts. Only
aggregates are read: cache status, response code and country. No client IP
or other per-visitor field is requested or stored.

See docs/wiki/services/family-public-site.md (nixosconfig #250).
"""

import json
import os
import sys
import threading
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ZONE = os.environ["CF_ZONE"]
HOST = os.environ["CF_HOST"]
TOKEN_FILE = os.environ["CF_TOKEN_FILE"]
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9472"))
STATE = os.path.join(os.environ["STATE_DIRECTORY"], "state.json")

WINDOW = timedelta(minutes=5)
# Adaptive analytics settle within a few minutes; read a window only once it
# is this far in the past.
LAG = timedelta(minutes=5)
# On a long outage, skip ahead rather than replay more than this.
MAX_CATCHUP = timedelta(hours=6)

QUERY = """
query($z: String!, $s: Time!, $e: Time!, $h: String!) {
  viewer { zones(filter: {zoneTag: $z}) {
    httpRequestsAdaptiveGroups(limit: 10000, filter: {
        datetime_geq: $s, datetime_lt: $e, clientRequestHTTPHost: $h}) {
      count
      sum { edgeResponseBytes visits }
      dimensions { cacheStatus edgeResponseStatus clientCountryName }
    }
  } }
}"""

lock = threading.Lock()
state = {
    "last_end": None,
    "requests": {},  # "cache|code" -> n
    "bytes": {},  # "cache" -> bytes
    "countries": {},  # "CC" -> n
    "visits": 0,
}
errors = 0
last_ok = 0.0


def floor_window(t):
    return t - timedelta(minutes=t.minute % 5, seconds=t.second,
                         microseconds=t.microsecond)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def fetch(start, end):
    with open(TOKEN_FILE) as f:
        token = f.read().strip()
    body = json.dumps({"query": QUERY, "variables": {
        "z": ZONE, "s": iso(start), "e": iso(end), "h": HOST}}).encode()
    req = urllib.request.Request(
        "https://api.cloudflare.com/client/v4/graphql", data=body,
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if out.get("errors"):
        raise RuntimeError(out["errors"])
    return out["data"]["viewer"]["zones"][0]["httpRequestsAdaptiveGroups"]


def add(groups):
    for g in groups:
        d = g["dimensions"]
        n = g["count"]
        cache = d["cacheStatus"] or "none"
        key = f"{cache}|{d['edgeResponseStatus']}"
        state["requests"][key] = state["requests"].get(key, 0) + n
        sent = g["sum"]["edgeResponseBytes"]
        state["bytes"][cache] = state["bytes"].get(cache, 0) + sent
        cc = d["clientCountryName"] or "XX"
        state["countries"][cc] = state["countries"].get(cc, 0) + n
        state["visits"] += g["sum"]["visits"]


def save():
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def poll_once():
    global last_ok
    target = floor_window(datetime.now(timezone.utc) - LAG)
    with lock:
        last = state["last_end"]
    # A first run backfills MAX_CATCHUP (covering the site's launch).
    start = (datetime.fromisoformat(last) if last else target - MAX_CATCHUP)
    start = max(start, target - MAX_CATCHUP)
    while start + WINDOW <= target:
        groups = fetch(start, start + WINDOW)
        with lock:
            add(groups)
            state["last_end"] = (start + WINDOW).isoformat()
            save()
        start += WINDOW
    last_ok = time.time()


def poller():
    global errors
    while True:
        try:
            poll_once()
        except Exception as e:  # keep serving the last good counters
            errors += 1
            print(f"poll failed: {e}", file=sys.stderr, flush=True)
        time.sleep(60)


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"')


def render():
    lines = []

    def metric(name, kind, help_):
        lines.append(f"# HELP {name} {help_}")
        lines.append(f"# TYPE {name} {kind}")

    with lock:
        metric("familypub_edge_requests_total", "counter",
               "Requests Cloudflare served for the site, by cache status and code.")
        for key, n in sorted(state["requests"].items()):
            cache, code = key.split("|")
            lines.append(f'familypub_edge_requests_total{{cache="{esc(cache)}",'
                         f'code="{esc(code)}"}} {n}')
        metric("familypub_edge_bytes_total", "counter",
               "Bytes Cloudflare sent to visitors, by cache status.")
        for cache, b in sorted(state["bytes"].items()):
            lines.append(f'familypub_edge_bytes_total{{cache="{esc(cache)}"}} {b}')
        metric("familypub_edge_country_requests_total", "counter",
               "Requests by visitor country (aggregate, no addresses).")
        for cc, n in sorted(state["countries"].items()):
            lines.append(f'familypub_edge_country_requests_total{{country="{esc(cc)}"}} {n}')
        metric("familypub_edge_visits_total", "counter",
               "Cloudflare 'visits': page views arriving from another site or none.")
        lines.append(f"familypub_edge_visits_total {state['visits']}")
        last = state["last_end"]
    metric("familypub_exporter_window_end_seconds", "gauge",
           "End of the newest five-minute window counted.")
    end = datetime.fromisoformat(last).timestamp() if last else 0
    lines.append(f"familypub_exporter_window_end_seconds {end}")
    metric("familypub_exporter_errors_total", "counter", "Failed polls.")
    lines.append(f"familypub_exporter_errors_total {errors}")
    metric("familypub_exporter_last_success_seconds", "gauge",
           "Time of the last successful poll.")
    lines.append(f"familypub_exporter_last_success_seconds {last_ok}")
    return ("\n".join(lines) + "\n").encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        out = render()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, format, *args):  # noqa: A002 (base signature)
        del format, args  # no request log: nothing per-visitor is kept


def main():
    if os.path.exists(STATE):
        with open(STATE) as f:
            state.update(json.load(f))
    threading.Thread(target=poller, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
