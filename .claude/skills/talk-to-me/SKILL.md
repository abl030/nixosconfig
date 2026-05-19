---
name: talk-to-me
description: Wire this Claude Code session into the voice.ablz.au SSE bridge so assistant replies are spoken aloud through the user's phone. Use when the user says "talk to me", "voice mode", "I'm in the car", "drive mode", or similar phrasing. Also use the unregister command when they say "stop talking", "turn off voice", or "I'm at the desk again".
---

# Talk to me — voice mode

Registers this session's transcript with the `claude-voice` service on doc1 so a phone-side TTS subscriber speaks your replies through the user's car Bluetooth.

## What this does

1. Computes the project's transcript directory: `~/.claude/projects/<encoded-cwd>/` where `<encoded-cwd>` is the absolute current working directory with every `/` replaced by `-`.
2. POSTs that path to `https://voice.ablz.au/register` — a tailnet-only endpoint on doc1.
3. After registration, the service tails the latest `.jsonl` in that directory and emits every assistant text block as an SSE event. The user's phone (subscribed to `/stream`) speaks each event aloud.

## Critical: how you must talk after this

The user is driving. They can't read a screen, they can only hear you. From the moment registration succeeds:

- **Short sentences.** Speak like a podcast, one thought per reply when possible.
- **No markdown tables, bullet lists, headings, code blocks, or inline `code` formatting** — they translate horribly to TTS. If you must reference a filename or command, just say it.
- **No diffs.** Describe what you'd change, don't paste it.
- **Acknowledge before working.** If a task will take a while, say so out loud before falling silent.
- The user can interrupt at any red light by dictating a new prompt. Don't get upset if they cut you off.

## Register

Run this bash one-liner. If it succeeds, your **next assistant message** is the handshake the user hears first — make it one short sentence confirming voice mode is live (e.g. *"Voice mode is on, you should hear me through the car now."*).

```bash
bash -c '
project="$HOME/.claude/projects/$(pwd | sed "s|/|-|g")"
curl -fsS -X POST "https://voice.ablz.au/register" \
  -H "Content-Type: application/json" \
  -d "{\"project\":\"$project\"}"
'
```

## Unregister

When the user wants to stop:

```bash
curl -fsS -X POST "https://voice.ablz.au/unregister"
```

Acknowledge in plain text. After this, normal markdown-heavy output resumes.

## Troubleshooting

- `Could not resolve host: voice.ablz.au` — Cloudflare DNS hasn't synced yet, or this machine isn't on the tailnet. Wait a minute, retry. If you're not on doc1, check Tailscale status.
- `Failed to connect to voice.ablz.au` — the voice service is down. Suggest `ssh doc1 systemctl status claude-voice`.
- `{"error":"not a directory: ..."}` — the project transcript dir doesn't exist yet because no messages have been written to this session. Wait for the user's next prompt, then retry.
- Phone hears nothing after registration — verify the Termux subscriber is running on the phone (`sv status voice-sub`). The service side will keep emitting silently regardless.
