---
name: feedback-gotify-long-task-notifier
description: User wants a Gotify phone ping when an agent finishes a LONG task and is waiting for input — but silence during live chat
metadata:
  type: feedback
---

The user runs many Claude agents (FleetView background jobs) and doesn't want to
keep checking Termux to see if one is waiting. They want a Gotify push **only**
when an agent goes away, grinds on a long task, and then stops needing input —
and **NO** ping during rapid live-chat back-and-forth (phone lighting up while
they're actively talking to it is the thing to avoid).

**Why:** reduce the anxiety/overhead of polling sessions; the phone push is the
"come back and look" nudge so they can walk around freely.

**How to apply:** Implemented (2026-06-26) as a harness hook on **doc1**, NOT a
behavior I produce — see `~/.claude/hooks/gotify-turn-ping.sh` + two hooks in
`~/.claude/settings.json` (real, hand-edited files in $HOME, NOT Nix/HM-managed —
same as the old bd hooks). Mechanism: `UserPromptSubmit` records turn-start time
per `session_id` under `~/.claude/turn-timers/`; `Stop` (async) pings
`gotify-ping` iff the turn ran ≥ threshold. Live-chat turns are short → stay
silent. Threshold = `CLAUDE_GOTIFY_PING_MIN_SECONDS` (default **180s**). Picks up
automatically on every NEW session; running sessions need `/hooks` or restart to
reload.

- Scope: **doc1 only** so far. To extend to epi/framework/etc., replicate the
  script + the two settings.json hooks in that host's `$HOME` (gotify-ping +
  `/run/secrets/gotify/token` already exist fleet-wide via HM).
- gotify mechanics: [[gotify-ping]] skill / `docs/wiki/services/gotify.md`.
- Don't confuse with claude.ai mobile push (`inputNeededNotifEnabled`) — user
  wants their self-hosted Gotify channel, not claude.ai push.
