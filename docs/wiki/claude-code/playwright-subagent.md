# Playwright MCP subagent

**Added:** 2026-04-17
**Status:** working
**Agent definition:** `.claude/agents/playwright.md`
**Wrappers:** `scripts/mcp-playwright.sh`, `scripts/playwright-chromium.sh`
**Package:** `pkgs.playwright-mcp` — already in `modules/home-manager/services/claude-code.nix`, so the `mcp-server-playwright` binary is on `PATH` on every Claude Code host.

## Why a subagent, not a project-level MCP

Playwright MCP exposes a couple dozen `browser_*` tools. Wiring it into the main session's `.mcp.json` would bloat every conversation's context whether or not the browser was needed. Per the CLAUDE.md MCP hygiene rule (same reason pfSense/UniFi/HA are subagent-only), Playwright is gated behind an explicit `Agent(subagent_type="playwright", ...)` call.

## Two-tier wrapper pattern

`scripts/mcp-playwright.sh` probes for a CDP-speaking Chromium on `127.0.0.1:9222` before falling back to letting Playwright spawn its own browser:

```
  curl /json/version on 9222
           │
    ┌──────┴──────┐
    yes          no
    │             │
    ▼             ▼
--cdp-endpoint   Playwright-managed
 (attach)         (spawn + teardown)
```

### Mode 1 — CDP attach (preferred on desktops)

Start a persistent Chrome once:

```sh
./scripts/playwright-chromium.sh            # launch (or no-op if up)
./scripts/playwright-chromium.sh --status   # check
./scripts/playwright-chromium.sh --stop     # kill it
```

This launches `google-chrome` with `--remote-debugging-port=9222 --user-data-dir=~/.cache/playwright-mcp-chromium/`, fully detached via `setsid -f`. The window survives:
- Claude Code exiting
- Terminal closing
- The MCP server process exiting (i.e. subagent shutdown)

**Why this is the killer feature:** without CDP attach, every subagent invocation spawns a fresh Chromium. You wait for it to launch, log back in (profile survives but the window doesn't), wait for the page to render, then the subagent finishes and the window closes. Next invocation: repeat. With CDP attach, the window stays up across an entire debugging session and the subagent just opens tabs in it.

### Mode 2 — Playwright-managed (default on servers / headless hosts)

If no CDP endpoint responds, the wrapper lets Playwright spawn its own Chromium. Headed vs headless is auto-detected from `DISPLAY`/`WAYLAND_DISPLAY`:

| Environment | Default |
|---|---|
| `DISPLAY` or `WAYLAND_DISPLAY` set | headed |
| neither set (SSH / server) | `--headless` |

Overrides (useful for forcing behaviour even with a display):

- `PLAYWRIGHT_MCP_FORCE_HEADLESS=1` — always headless
- `PLAYWRIGHT_MCP_FORCE_HEADED=1` — always headed (will fail if no display)

Managed-mode profile lives under Playwright's default user-data-dir. State survives, but the window itself closes on MCP exit — that's the mode the CDP pattern is designed to avoid.

## Profile state

Two separate profiles depending on mode:

| Mode | Profile path | Notes |
|---|---|---|
| CDP attach | `~/.cache/playwright-mcp-chromium/` | Dedicated — intentionally separate from your normal Chrome profile so Playwright can't pollute it |
| Playwright-managed | `~/.cache/ms-playwright/mcp-*/` | Playwright's own user-data-dir. Leftover on managed-mode exits |

To reset a Grafana/service login cleanly, delete the relevant dir and restart.

## Gotchas

### One-time login per profile

The CDP profile starts empty — first session needs a manual login for every authenticated service (e.g. Grafana on logs.ablz.au). After that the cookie persists indefinitely.

The agent prompt in `.claude/agents/playwright.md` knows this: if it lands on a login page, it tells the user to log in and polls until the URL leaves `/login`. Don't hardcode credentials anywhere — just log in interactively.

### Agent discovery happens at session start

Adding a new subagent file under `.claude/agents/` requires restarting Claude Code before `subagent_type: <name>` is addressable. In-session `Agent()` calls use the agent list that was scanned at launch.

### CDP port is user-scoped, not host-scoped

Port 9222 is bound on `127.0.0.1` so it's safe from the LAN but not from other user accounts on the same host. On shared machines, set `PLAYWRIGHT_MCP_CDP_PORT=<something>` on both the launcher and the MCP wrapper to pick a unique port per user.

### Screenshots land in `.playwright-mcp/`

The MCP's default output dir is a gitignored `.playwright-mcp/` at the project root. Mentioned in `.gitignore` so random PNGs don't pollute commits.

### Wayland flag is added at launch time, not runtime

`scripts/playwright-chromium.sh` adds `--ozone-platform=wayland` if `WAYLAND_DISPLAY` is set at launch time. If you start Chrome from an SSH session with forwarding and then log into a Wayland session on the same machine, Chrome keeps its original ozone setting — restart the launcher (`--stop` then launch) to re-detect.

## When NOT to use this agent

- Static HTML or JSON fetches → `WebFetch` or `curl`.
- Log/metric queries that don't need UI rendering → Loki HTTP API directly (`loki.ablz.au/loki/api/v1/query_range`).
- Anything stateless and scriptable with no interactive DOM — a browser is overkill.

Playwright earns its keep when the thing being tested IS the rendered UI: Grafana dashboards, Home Assistant frontend, Overseerr, anything with JS-driven state that doesn't round-trip to a clean API.

## Related

- `.claude/agents/playwright.md` — agent definition + embedded prompt (Grafana / logs.ablz.au workflow notes live here)
- `scripts/mcp-playwright.sh` — two-mode wrapper
- `scripts/playwright-chromium.sh` — persistent Chrome launcher
- `modules/home-manager/services/claude-code.nix` — packages `playwright-mcp` for all Claude Code hosts
