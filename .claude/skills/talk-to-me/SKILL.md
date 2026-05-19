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

- **NO WALLS OF TEXT.** This is the single most important rule — keep every reply short. A few sentences max. If the user asks about multiple items (e.g. several wine batches), give a tight one- or two-sentence summary per item, not a paragraph each. When in doubt, cut it in half. The user has called this out before — do not make them ask again.
- **Short sentences.** Speak like a podcast, one thought per reply when possible.
- **No markdown tables, bullet lists, headings, code blocks, or inline `code` formatting** — they translate horribly to TTS. If you must reference a filename or command, just say it.
- **No diffs.** Describe what you'd change, don't paste it.
- **Acknowledge before working.** If a task will take a while, say so out loud before falling silent.
- The user can interrupt at any red light by dictating a new prompt. Don't get upset if they cut you off.

## Register

The user expects this to "just work" — they will not touch the phone. Run **both** of the commands below. The first brings the phone subscriber up cleanly and clears any stale orphans; the second registers this Claude session with the server.

If the first command fails, stop and surface the error — registering on the server while the phone is silent is worse than failing loudly. Once both succeed, your **next assistant message** is the user's first handshake — make it one short sentence confirming voice mode is live (e.g. *"Voice mode is on, you should hear me through the car now."*).

```bash
ssh -o ConnectTimeout=8 phone 'sh -s' <<"REMOTE"
set -e
export SVDIR=$PREFIX/var/service LOGDIR=$PREFIX/var/log
# Non-interactive SSH skips Termux's profile.d, so runsvdir may not be up.
pgrep -f runsvdir >/dev/null || service-daemon start >/dev/null 2>&1
# Kill any orphan voice-sub run scripts (parent died but they kept going).
for pid in $(pgrep -f "voice-sub/run" 2>/dev/null); do
  ppid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
  [ "$ppid" = "1" ] && kill -9 "$pid" 2>/dev/null || true
done
# Drop any stale termux-tts-speak calls — they jam the Android TTS engine.
pkill -9 -f termux-tts-speak 2>/dev/null || true
sleep 1
sv start voice-sub >/dev/null 2>&1
sleep 2
sv status voice-sub
REMOTE
```

```bash
project="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"
curl -fsS -X POST https://voice.ablz.au/register \
  -H 'Content-Type: application/json' \
  -d "{\"project\":\"$project\"}"
```

## Unregister

When the user wants to stop. This also stops the phone subscriber so the device stops holding the wake lock.

```bash
curl -fsS -X POST https://voice.ablz.au/unregister
ssh -o ConnectTimeout=8 phone 'export SVDIR=$PREFIX/var/service LOGDIR=$PREFIX/var/log; sv stop voice-sub' || true
```

Acknowledge in plain text. After this, normal markdown-heavy output resumes.

## Troubleshooting

- `Could not resolve host: voice.ablz.au` — Cloudflare DNS hasn't synced yet, or this machine isn't on the tailnet. Wait a minute, retry. If you're not on doc1, check Tailscale status.
- `Failed to connect to voice.ablz.au` — the voice service is down. Suggest `ssh doc1 systemctl status claude-voice`.
- `{"error":"not a directory: ..."}` — the project transcript dir doesn't exist yet because no messages have been written to this session. Wait for the user's next prompt, then retry.
- `ssh: connect to host ... port 8022: ...` — phone is off, asleep, or off the tailnet. Surface this to the user; they need to wake/connect the phone before voice mode can work.
- `sv status` shows `down` after the bootstrap — `service-daemon start` may have failed. Suggest the user open the Termux app once so its profile.d starts runsvdir, then retry.
- TTS works once then goes silent — usually means orphan termux-tts-speak processes are jamming the Android TTS engine. The bootstrap block above clears them; if it doesn't, ask the user to force-stop the Termux:API app from Android Settings, then retry.
