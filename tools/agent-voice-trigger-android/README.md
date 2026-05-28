# Agent Voice Trigger Android

Tiny one-user Android helper for `talk-to-me` handsfree input.

The app asks Termux to run:

```sh
/data/data/com.termux/files/home/.local/share/agent-voice-input/agent-voice-input-termux.sh
```

The app does not record audio, hold credentials, talk to Whisper, or SSH
anywhere. Termux does all of that through the existing script.

Trigger routes:

- in-app "Trigger Now" button, already proven end-to-end
- `ACTION_ASSIST` / `ACTION_VOICE_COMMAND` activity intent
- minimal `VoiceInteractionService` so Android may offer the app as a default
  digital assistant
- best-effort foreground `MediaSession` and accessibility media-button capture

The headset play/pause route is intentionally treated as best-effort only.
Android routes that key to the active media session, so it is not a reliable
push-to-talk control while another app owns playback.

## Required phone setup

- Termux and Termux:API installed.
- The `talk-to-me` skill has installed the Termux script/config.
- Termux has `allow-external-apps = true` in `~/.termux/termux.properties`.
- Android grants this app the Termux `Run commands in Termux environment`
  permission.
- For the assistant experiment, set this app under Android Settings -> Apps ->
  Default apps -> Digital assistant app, if Android lists it.

## Build

Use `./build-apk.sh` with `ANDROID_HOME` or `ANDROID_SDK_ROOT` pointing at a
minimal Android SDK that contains platform 35 and build-tools 35.
