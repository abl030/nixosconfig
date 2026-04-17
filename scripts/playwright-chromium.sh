#!/usr/bin/env bash
# Launch a persistent Chromium/Chrome window with CDP exposed on 127.0.0.1:9222.
# Idempotent: if already running, does nothing.
# See docs/wiki/claude-code/playwright-subagent.md for the full design + gotchas.
#
# Paired with scripts/mcp-playwright.sh — when this browser is running, the
# Playwright MCP wrapper connects via --cdp-endpoint instead of spawning its
# own Chromium. That way the window survives MCP server exits (i.e. subagent
# shutdown), so repeated agent invocations don't keep popping new windows.
#
# Profile lives at ~/.cache/playwright-mcp-chromium/ — dedicated, separate
# from your normal Chrome profile. Log in to services here once and the
# session persists.
#
# Usage:
#   ./scripts/playwright-chromium.sh            # launch (or no-op if up)
#   ./scripts/playwright-chromium.sh --stop     # kill the launched instance
#   ./scripts/playwright-chromium.sh --status   # print state
set -euo pipefail

CDP_PORT="${PLAYWRIGHT_MCP_CDP_PORT:-9222}"
DATA_DIR="${HOME}/.cache/playwright-mcp-chromium"
PID_FILE="${DATA_DIR}/chromium.pid"

is_running() {
  curl -sf "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1
}

case "${1:-}" in
  --status)
    if is_running; then
      echo "running (CDP http://127.0.0.1:${CDP_PORT})"
      exit 0
    else
      echo "not running"
      exit 1
    fi
    ;;
  --stop)
    if [[ -f "$PID_FILE" ]]; then
      pid=$(cat "$PID_FILE")
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "stopped pid $pid"
      fi
      rm -f "$PID_FILE"
    else
      echo "no pid file; nothing to stop (remaining Chrome may be unrelated)"
    fi
    exit 0
    ;;
esac

if is_running; then
  echo "Chromium already running on CDP port ${CDP_PORT} — reusing." >&2
  exit 0
fi

BROWSER="$(command -v chromium 2>/dev/null || command -v google-chrome-stable 2>/dev/null || command -v google-chrome 2>/dev/null || true)"
if [[ -z "$BROWSER" ]]; then
  echo "Error: no chromium/google-chrome on PATH — install one first." >&2
  exit 1
fi

mkdir -p "$DATA_DIR"

# Wayland hint if a Wayland session is active; harmless under X11 (Chrome
# falls back automatically).
ozone=()
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  ozone=(--ozone-platform=wayland)
fi

# setsid -f = fork + become session leader; fully detaches from this shell
# so the browser survives `claude-code` exit / terminal close.
setsid -f "$BROWSER" \
  --remote-debugging-port="${CDP_PORT}" \
  --user-data-dir="$DATA_DIR" \
  --no-first-run \
  --no-default-browser-check \
  --disable-features=InfiniteSessionRestore \
  "${ozone[@]}" \
  about:blank \
  >"${DATA_DIR}/chromium.log" 2>&1 </dev/null

# Wait for CDP to come up (up to ~8s) and capture pid.
for _ in $(seq 1 40); do
  if is_running; then
    pid=$(pgrep -f "remote-debugging-port=${CDP_PORT}.*user-data-dir=${DATA_DIR}" | head -1 || true)
    [[ -n "$pid" ]] && echo "$pid" >"$PID_FILE"
    echo "Chromium started on CDP http://127.0.0.1:${CDP_PORT} (pid ${pid:-?})" >&2
    exit 0
  fi
  sleep 0.2
done

echo "Error: Chromium did not expose CDP on port ${CDP_PORT} within 8s." >&2
echo "See log: ${DATA_DIR}/chromium.log" >&2
exit 1
