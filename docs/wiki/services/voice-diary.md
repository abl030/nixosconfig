# Voice diary — car recordings to dated transcripts

Date: 2026-09-10
Status: pipeline built and verified on doc2. **Syncthing pairing is the one
remaining manual step** — see "Finishing the transport" below.
Related: [whisper-vad-long-audio](whisper-vad-long-audio.md),
`modules/nixos/services/voice-diary.nix`, `scripts/voice-diary-ingest.py`

## Why

Sitting down to write a diary doesn't happen. Talking on the commute does. The
goal is: press record getting into the car, stop when you arrive, and later find
the transcript waiting — with no phone fiddling and nothing sent to a third
party.

## Shape

```
phone (Easy Voice Recorder)
  -> /storage/emulated/0/Recordings
  -> Syncthing (receive-only on the doc2 side)
  -> /mnt/data/Life/Andy/VoiceRecordings        [dropDir, read-only to the unit]
  -> voice-diary.timer (every 10 min, scans)
  -> whisper.ablz.au  (igpu, Silero VAD, ~4.4x realtime)
  -> /mnt/data/Life/Zet/Projects/Diary/Inbox    [inboxDir]
       2026-09-10_161703.m4a
       2026-09-10_161703.md
```

Both halves of a pair share a timestamp basename, so audio and transcript sit
together and the inbox sorts chronologically. Filing into the dated diary tree
is left to the user on purpose — see "No AI in the loop".

## Three decisions that are easy to get wrong

### 1. A timer, not a `systemd.path` unit

Both directories are on `/mnt/data`, which is NFS from tower. **inotify does not
work over NFS**, so a path unit would look correct, deploy cleanly, and silently
never fire. The service scans on a timer instead. Ten minutes is deliberate: a
diary entry has no latency requirement, and whisper-server processes one request
at a time, so a tighter loop would just compete with the Dictate phone keyboard
for the same backend.

### 2. The drop directory is read-only, and that is a data-safety property

The doc2 side of the Syncthing folder must be **receive-only**, and the unit
binds `dropDir` with `BindReadOnlyPaths`. The phone holds the only other copy of
these recordings. If doc2 ever deleted or rewrote a file there, Syncthing would
faithfully propagate that back and destroy the original on the phone. The ingest
copies out and never removes; the read-only bind means a future bug in the
script cannot change that.

`BindPaths`/`BindReadOnlyPaths` rather than `ReadWritePaths` also because the
sources are NFS-backed: bind mounts fail loudly with `status=226/NAMESPACE`,
whereas `ReadWritePaths` silently skips a missing source and surfaces as `EROFS`
hours later. There is an `errorPatterns` rule for exactly that.

### 3. No AI in the loop

The instinct is that filing needs intelligence. It doesn't. A diary is indexed
by **date**, and the recording already carries its own date in its mtime, so the
name and the destination are both deterministic. The only things that would need
a model are a title, topic-splitting, or todo extraction — all optional garnish.

If that is added later it should use the fleet's own `llama-cpp-vulkan` on igpu
(already deployed for `mailsearch-embed`), **not** a third-party API. These are
personal diary entries; they should not leave the fleet.

## Behaviour worth knowing

- **Idempotency is by output existence**, not a state file. If `<stamp>.md`
  exists, the source is skipped. A crashed run is safe to repeat.
- **The transcript is renamed into place last**, after the audio is already
  beside it, because it doubles as the idempotency marker.
- **`minAgeSeconds` (default 120)** skips files touched recently, so a recording
  still being replicated by Syncthing isn't transcribed half-written.
- **Failures are left alone and retried** on the next tick. A single `FAILED`
  line is therefore not alerted — only "can't see the recordings at all" is.
- **Dotted paths are ignored**: Syncthing's `.stfolder`/`.stversions` and Easy
  Voice Recorder's `.evr_recently_deleted_*` tombstones.
- **Local time, deliberately.** Names use local wall-clock, not UTC — an evening
  Perth recording is the previous day in UTC and would file under the wrong date.

## Finishing the transport

The pipeline works on any directory; Syncthing is just how files get there. To
finish it:

1. On the phone, get the Syncthing **device ID** (Settings → Show device ID).
   Note the official Android app was **discontinued in Dec 2024** — prefer
   Syncthing-Fork (`com.github.catfriend1.syncthingandroid`).
2. Grant Syncthing **All files access**, or it cannot see `/storage/emulated/0/Recordings`.
3. Add to doc2's `homelab.syncthing`:

```nix
extraDevices.phone = {
  id = "<device-id-from-the-phone>";
  name = "phone";
};
extraFolders.voice-recordings = {
  id = "voice-recordings";
  path = "/mnt/data/Life/Andy/VoiceRecordings";
  devices = ["phone"];
  type = "receiveonly";   # REQUIRED - see decision 2 above
};
```

`type = "receiveonly"` is not a preference. Anything else risks deleting the
recordings on the phone.

## Recorder settings

Easy Voice Recorder, on the phone:

- Save folder → `/storage/emulated/0/Recordings` (not app-private storage, which
  nothing else can read).
- Battery → **Unrestricted**. Samsung is aggressive about killing background
  apps and a long recording with the screen off is a prime target.
- Turn the gain down slightly — the first real recording clipped 1,240 samples
  at 0 dB.

## Testing without a phone

Drop an audio file into `dropDir`, set its mtime, and start the unit:

```bash
sudo systemctl start voice-diary.service
journalctl -u voice-diary -n 20 --no-pager
```

The unit is a `oneshot`; the timer only decides when it runs.

## When to revisit

- **Whisper is the bottleneck, and it is shared.** A long recording blocks the
  Dictate keyboard for the duration. If that becomes annoying, point
  `voiceDiary.model` at a smaller alias, or give long-form its own backend.
- The vhost needs `proxyTimeout` raised (set to `1800s`); nginx's 60s default
  hard-504s a real recording. See [whisper-vad-long-audio](whisper-vad-long-audio.md).
- If the inbox grows faster than it is filed, that is the signal to add the
  local instruct model for titles/summaries — not to automate the filing.
