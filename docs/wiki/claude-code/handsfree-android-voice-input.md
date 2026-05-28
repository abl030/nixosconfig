# Handsfree Android Voice Input For Agent Sessions

Date researched: 2026-05-27
Status: feasible as a one-user Termux + sideloaded-app workflow; Bluetooth headset media-button ownership is constrained by Android/media-session routing.

## Problem

The current `talk-to-me` voice mode is output-only:

- `claude-voice` tails the active Claude transcript and sends assistant text to the phone over SSE.
- The phone speaks replies with Termux TTS.
- User input still comes from Android keyboard dictation, which requires tapping to start/stop and sometimes tapping Enter.

That interaction is too distracting while driving or running. The desired replacement is a phone-side push-to-talk path triggered by a steering-wheel, earbud, headset, or other physical button.

## Existing Infrastructure

- `whisper.ablz.au` is already an OpenAI-compatible Whisper endpoint, tailnet-only, backed by `modules/nixos/services/whisper-server.nix`.
- Dictate Keyboard already proves the transcription leg works: phone records audio, posts to `/v1/audio/transcriptions`, and gets text back.
- `voice.ablz.au` is already a tailnet-only bridge, but today only exposes assistant-output endpoints: `/register`, `/unregister`, `/stream`, `/healthz`.

## Android Findings

Useful official APIs exist:

- `Intent.ACTION_VOICE_COMMAND` can launch an Activity for a voice-command request. Current Android docs explicitly describe Bluetooth headset / LE Audio extras and recommend starting headset voice recognition plus `AudioRecord` with a preferred Bluetooth device when applicable.
- `MediaSession` can receive Bluetooth/headset/media key events through `onMediaButtonEvent`. This is the likely path for play/pause/next/previous style buttons, including some steering-wheel media controls.
- `MediaRecorder` or `AudioRecord` can capture short clips with `RECORD_AUDIO`; `VOICE_RECOGNITION` or `VOICE_COMMUNICATION` are the sensible audio sources.
- Android 14+ foreground services require explicit service types. A microphone foreground service needs `FOREGROUND_SERVICE_MICROPHONE` and `RECORD_AUDIO`, and background mic startup has while-in-use restrictions.

Useful commands exist for sideloading/testing:

- `adb install -r app-debug.apk`
- `adb shell input keyevent KEYCODE_MEDIA_PLAY_PAUSE`
- `adb shell input keyevent KEYCODE_HEADSETHOOK`
- `adb shell am start -a android.intent.action.VOICE_COMMAND <package>/<activity>`

In this repo environment, `adb`, Gradle, JDK, and Android SDK packages are available via nixpkgs even when not globally installed. `adb` was verified with `nix shell --inputs-from . nixpkgs#android-tools -c adb version`.

## Prior Art

- AutoVoice/Tasker, Automate, and MacroDroid all support variants of Bluetooth/media-button voice triggers. This proves the OS path is real, but also shows reliability is device-dependent.
- Termly takes a different path: a local CLI spawns the coding agent inside a PTY, streams terminal I/O over an end-to-end encrypted WebSocket relay, and the mobile app provides its own UI and microphone button. It does not appear to solve headset/earbud hardware-button capture; its published voice path is "tap the microphone icon in Termly".
- OpenClaw Assistant is a broad self-hosted Android assistant using `VoiceInteractionService`, STT, TTS, wake word, and Android assistant integration.
- Prontafon and phone-whisper are closer to dictation workflows: Android records speech, transcribes, and inserts/sends text elsewhere.
- Flic / dedicated BLE buttons are common in push-to-talk products and avoid many headset/media-button conflicts.

## Android Auto Boundary

Treat Android Auto as audio transport, not as the app platform for v0.

Normal third-party Android Auto apps must fit allowed car categories and safety templates. A coding-agent voice client does not fit cleanly. Owning the steering-wheel voice-assistant button globally is controlled by Android/Google assistant plumbing, not arbitrary apps. Steering-wheel media buttons may still reach a phone `MediaSession`, but this is not guaranteed across cars and head units.

## Feasible V0

Build a tiny sideloaded Android app:

1. Foreground Activity with one large push-to-talk button for setup/testing.
2. Declare an Activity for `ACTION_VOICE_COMMAND`.
3. Optional foreground service with active `MediaSession` to capture media buttons.
4. On trigger: start recording.
5. On second trigger, silence timeout, or max duration: stop recording.
6. POST audio to `https://whisper.ablz.au/v1/audio/transcriptions` with `model=large`.
7. POST transcript to a new input endpoint on the homelab side.

The server-side input endpoint is the remaining design decision. Options:

- Direct agent input bridge: extend `claude-voice` with `/input`, and require the active agent session to be running in a known tmux pane so the service can send text plus Enter. This is simple and private but terminal-specific.
- Full custom voice client: Android app talks to a backend that runs/controls the agent directly. This is cleaner long term but no longer just a wrapper around the current CLI session.
- IME/accessibility wrapper: app inserts text into the currently focused phone UI and taps send. This matches the current Dictate workflow but is more fragile and more Android-permission-heavy.

For a one-user APK, the best first spike is the direct input bridge with an explicit registered sink. Do not attempt a Play Store-safe Android Auto app for v0.

## Easier No-APK Spike: Termux + Tasker

After checking the existing phone environment, there is an easier path than building an APK first:

- Termux already has `termux-microphone-record`.
- Termux already has `curl`, `jq`, and `ssh`.
- The phone can SSH to `doc1`.
- `doc1` has `tmux`.

That means the first working prototype can be:

1. Run the active agent session inside a known `tmux` pane on `doc1`.
2. Put a toggle script on the phone.
3. First trigger starts `termux-microphone-record` to a temp file.
4. Second trigger stops recording with `termux-microphone-record -q`.
5. The script POSTs the audio file to `https://whisper.ablz.au/v1/audio/transcriptions`.
6. The script injects the transcript into the known `tmux` pane with SSH.

Use `tmux load-buffer` + `tmux paste-buffer` rather than shell-quoting the transcript into `tmux send-keys`; speech text can contain quotes, newlines, and shell metacharacters.

Trigger options, in increasing robustness:

- Termux:Widget or a launcher shortcut for bench testing.
- Tasker `Media Button` or AutoVoice `BT Pressed` to call the Termux script.
- A dedicated BLE button such as Flic if steering-wheel/headset media-button capture is unreliable.
- Custom APK only after the no-APK path proves the interaction model.

This keeps Android native development out of the first experiment. It does not require creating a terminal UI or embedding SSH in an app; Termux is just the phone-side script runner.

Security note: phone SSH access to `doc1` should eventually use a restricted key or a small authenticated `/input` endpoint. For a spike, using the existing Termux SSH client is acceptable if the target is a single `tmux` pane and the script is kept narrow.

## Live MVP Result: Termux + Tiny Trigger App

Implemented and tested on 2026-05-27:

- `talk-to-me` can detect the current tmux pane and install phone config.
- `agent-voice-input-termux.sh` records via `termux-microphone-record`, posts to `whisper.ablz.au`, and SSHes transcript text back to the tmux pane.
- `agent-voice-inject.sh` pastes text safely through a tmux buffer and presses Enter.
- A tiny sideloaded app under `tools/agent-voice-trigger-android/` can trigger the Termux script from an in-app button.
- End-to-end app-button test succeeded: spoken audio was transcribed and injected as a Codex prompt.
- Version `0.3` of the tiny app adds `ACTION_ASSIST`, `ACTION_VOICE_COMMAND`, and a minimal `VoiceInteractionService` so Android can be tested through the default digital assistant path.

The Bluetooth headset media-button path did not succeed reliably. Pressing headset play/pause continued to start/stop the active music app rather than being consistently routed to the trigger app, even with a foreground service and active `MediaSession`.

This matches the expected Android limitation: media buttons are routed through the current media-session/audio-focus stack and are not a reliable generic push-to-talk input when another media app owns playback.

The app includes an Accessibility key-filtering path as an experiment, but this is a broad Android permission and should not be treated as a clean default. If headset interception remains unreliable, prefer one of:

- a dedicated BLE button that can be bound to the app or a Termux command,
- an Android automation app with proven device-specific media-button capture,
- using the app's own large button or a future notification action as the v0 trigger,
- an Android assistant-button / `ACTION_VOICE_COMMAND` route if the headset exposes an assistant gesture separate from media play/pause.

## Follow-up Research: Ways Around Headset Media Routing

Research after the live test points to these options:

1. Default assistant / voice-command path. Android has a first-class `VoiceInteractionService` role for the current global voice interactor, and the selected service is kept running by the system. Android's `ACTION_VOICE_COMMAND` docs explicitly describe Bluetooth headset and LE Audio extras, and recommend starting headset voice recognition plus `AudioRecord` against the originating Bluetooth device. This is the most promising software-only path if the headset exposes a separate assistant gesture. It means the APK becomes a minimal assistant app whose session starts the Termux recorder.
2. Headphone assistant gesture. Google's own headphone docs distinguish assistant gestures from media play/pause gestures: press-and-hold or touch-and-hold can start Assistant, while media play/pause remains a separate gesture. This is worth testing before writing more code. If the headset only exposes play/pause, skip this path. If it exposes "assistant", set the custom app as the phone's default digital assistant and test that gesture. Live Samsung Buds testing showed another vendor gate: Galaxy Wearable can list the custom assistant but reject it for Buds pinch-and-hold with "your current digital assistant can't be used with earbuds pinch and hold controls." Treat Buds assistant launch as Samsung/Google/Gemini-specific, not generic Android assistant dispatch.
3. Accessibility key filtering. Android documents `FLAG_REQUEST_FILTER_KEY_EVENTS` and `onKeyEvent` as a way for an accessibility service to receive key events before apps and consume them. The APK includes this experiment, but Android 13+ restricts accessibility for sideloaded apps, and it is a broad permission. Treat as a last-resort personal hack, not a clean architecture.
4. Automation apps. Tasker, AutoVoice, Key Mapper, Automate, and MacroDroid all have media-button or hardware-key stories, but community reports repeatedly show Bluetooth headset handling is device- and Android-version-dependent. Key Mapper explicitly lists headsets/headphones and the voice-assistant button as supported trigger classes. MacroDroid documents a media-button trigger, but notes device-specific behavior and long-press/default-assistant conflicts. These tools may beat our custom APK because they have years of compatibility work, but they still cannot guarantee play/pause ownership while a music app has the active media session.
5. Dedicated BLE/PTT button. PTT products such as Zello document explicit Bluetooth PTT-button pairing, and Flic-style buttons are designed to trigger app actions without pretending to be the media play/pause key. This is the most reliable hardware path if assistant-button routing fails. For this project, the button action should call the existing Termux command or launch the tiny APK trigger activity.

Conclusion: stop treating Bluetooth media play/pause as the target. The current software spike is the minimal default-assistant/`ACTION_VOICE_COMMAND` implementation, because that matches Android's intended route for headset voice gestures, but Samsung Buds gate that route too. Google/Pixel Buds documentation also describes the earbud gesture in terms of Google Assistant or Gemini, not arbitrary third-party assistant services. If the user's hardware cannot produce an assistant/PTT-specific event that reaches our app, use a dedicated BLE button instead. The app-button MVP proves the speech pipeline; the missing piece is a hardware event Android is willing to route to us.

## Google Assistant Workaround

Let Google/Gemini keep ownership of the earbud assistant gesture, then use it to launch the trigger app:

- "Hey Google, open Agent Voice Trigger" should launch the app by name.
- The APK can be changed so launcher start immediately runs the Termux command, or a separate launcher alias such as "Talk to Codex" can do that while the normal app icon remains a settings screen.
- Full Google Assistant App Actions / feature shortcuts are probably heavier than needed and may depend on Play-distributed app metadata. For this one-user sideloaded app, "open app" is the lowest-friction Google route.

This is not as good as a button, but it avoids Samsung's Buds control gate.

## Least Privilege Notes

- Keep Whisper and input endpoints tailnet-only.
- Add a per-session random token to any `/input` endpoint; do not accept unauthenticated text injection from the whole tailnet.
- Avoid always-on background recording. Start capture only from user-initiated button/assistant/media events.
- Prefer a short max recording duration and visible foreground notification while recording.
- Avoid broad Android permissions: start with `RECORD_AUDIO`, `INTERNET`, `BLUETOOTH_CONNECT` only if needed for headset routing, and foreground-service permissions only if a service is used.

## Sources

- Android media buttons: https://developer.android.com/media/legacy/media-buttons
- Android MediaSession: https://developer.android.com/media/media3/session/control-playback
- Android ACTION_VOICE_COMMAND: https://developer.android.com/reference/android/content/Intent#ACTION_VOICE_COMMAND
- Android foreground service types: https://developer.android.com/develop/background-work/services/fgs/service-types
- Android MediaRecorder: https://developer.android.com/media/platform/mediarecorder
- Android Accessibility key filtering: https://developer.android.com/reference/android/accessibilityservice/AccessibilityServiceInfo#FLAG_REQUEST_FILTER_KEY_EVENTS
- Android `VoiceInteractionService`: https://developer.android.com/reference/android/service/voice/VoiceInteractionService
- Android restricted settings: https://support.google.com/android/answer/12623953
- Android Automotive Voice Interaction app skeleton: https://source.android.com/docs/automotive/voice/voice_interaction_guide/app_development
- AOSP VoiceInteractionService sample: https://android.googlesource.com/platform/development/+/HEAD/samples/VoiceInteractionService/
- Google Assistant on headphones: https://support.google.com/assistant/answer/9027902
- Google Pixel Buds Assistant/Gemini controls: https://support.google.com/googlepixelbuds/answer/7560032
- Google Assistant app launch/App Actions docs: https://developer.android.com/develop/devices/assistant/overview
- Termly CLI architecture: https://github.com/termly-dev/termly-cli/blob/main/docs/ARCHITECTURE.md
- Termly communication protocol: https://github.com/termly-dev/termly-cli/blob/main/COMMUNICATION_PROTOCOL.md
- Termly product page: https://termly.dev/
- Termly Claude Code mobile guide: https://termly.dev/blog/claude-code-mobile-setup-guide
- Key Mapper: https://play.google.com/store/apps/details?id=io.github.sds100.keymapper
- Key Mapper keymaps docs: https://keymapper.app/user-guide/keymaps/
- MacroDroid media-button trigger: https://macrodroidforum.com/wiki/index.php/Trigger%3A_Media_Button_Pressed
- OpenClaw Assistant: https://github.com/yuga-hashimoto/openclaw-assistant
- AutoVoice: https://play.google.com/store/apps/details?id=com.joaomgcd.autovoice
- Prontafon: https://prontafon.com/
- Zello Bluetooth PTT button pairing: https://support.zello.com/hc/en-us/articles/230745407-Pairing-a-Bluetooth-PTT-Button-Android
- Flic app control: https://flic.io/business/app-control
