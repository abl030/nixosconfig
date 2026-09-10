# Whisper VAD for long-form audio

Date: 2026-09-10
Status: implemented; deploy to igpu and end-to-end verification pending at time
of writing. The regression case is a real 16m49s car recording — see
"How to verify" below.
Related: `modules/nixos/services/whisper-server.nix`, [lgtm-stack](lgtm-stack.md)

## Problem

whisper.cpp degenerates into a **repetition loop** when transcribing a long
recording in a single pass. Measured on a real 16m49s voice-diary recording made
in a moving car:

- The last ~90 seconds collapsed into 36 lines alternating between
  `And then, uh.` and `I'll take a photo of dad.`
- The words spoken in that window were genuinely lost — replaced by stutter.

This matters for any long-form use (voice diary, meeting capture). It does not
affect the short clips the Dictate phone keyboard sends, which are 1–3 seconds.

## The audio was not the problem

Worth recording because the obvious diagnosis is wrong:

- Tail audio levels were **identical** to the body: mean -18.8 dB vs -18.0 dB.
  No silence, no noise spike, no dropout.
- Cutting the same 110 seconds out and transcribing them **alone** produced a
  clean, fully punctuated 321-word transcript.

Same audio, same model, same server — the only difference was decode context
length. The failure is in the decoder, not the recording.

## What was tried

| Approach | Result |
|---|---|
| Single pass, 16m49s | Loop in final ~90s. 2934 words, tail garbage. |
| Isolate tail (110s) alone | **Clean.** Proves audio is fine. |
| Fixed 255s chunks | No loop, tail recovered. But chunk 3 of 4 returned 0/78 lines capitalised, 1/78 punctuated. |
| `no_context=true` on the bad chunk | **No effect.** Rules out cross-request context bleed. |
| Fixed 120s chunks | No loop. Still 3 of 9 chunks returned all-lowercase, unpunctuated. |
| Split on silence | **Impossible for car audio.** Only 2 silences in 17 minutes even at -40 dB — the cabin noise floor never drops. |

Client-side chunking therefore trades a repetition loop for unpredictable
punctuation/casing loss, and cannot be made boundary-aware for noisy input.

## The fix

whisper.cpp 1.9.2 ships built-in Silero VAD. Enabled by default in the module:

```nix
homelab.services.whisper-server.vad = {
  enable = true;                    # default
  threshold = 0.5;                  # speech probability, 0.0-1.0
  maxSpeechDurationSeconds = 30;    # the anti-loop control
};
```

`--vad-max-speech-duration-s` is the part that matters. It auto-splits any speech
run longer than the cap, so the decoder never reaches the state where it
degenerates — while splitting on *detected speech* rather than a stopwatch, which
is what silence-splitting could not do.

The Silero weights are pinned with `fetchurl`, **not** fetched in `preStart`: the
`whisper-cpp-download-ggml-model` script bundled with the package predates VAD
models and only knows the `ggerganov/whisper.cpp` repo. The VAD weights live
under `ggml-org/whisper-vad`.

## Secondary benefit: no proxy timeout change needed

`whisper.ablz.au` sits behind nginx with the default `proxy_read_timeout 60s`,
and `local_proxy.nix` has no timeout option. A 20-minute upload returned a hard
**504 at exactly 60.05s** while the backend kept working. Two ways around it:

1. Server-side callers can talk to the dispatcher directly on igpu at
   `127.0.0.1:9875`, bypassing nginx entirely. This is what the verification
   used.
2. Adding a `proxyTimeout` option to `local_proxy.nix`, mirroring the existing
   `maxBodySize`, if a *client* ever needs to send long audio through the vhost.

Option 2 is still unimplemented. Do it if a phone or laptop ever needs to POST a
full-length recording to the public FQDN.

## Performance reference

Measured on igpu (Vulkan, AMD iGPU, `large-v3-turbo`):

- 20 min of audio → 6m05s (~3.3× realtime)
- 16m49s of audio → 5m43s (~3.5× realtime)
- 2-minute chunks → 34–40s each (comfortably under the nginx 60s cap)

whisper-server handles **one request at a time** per model instance; concurrent
requests queue behind each other. A long job blocks the Dictate keyboard until
it finishes.

## How to verify

The regression test is a long, noisy, single-pass recording — the exact case that
failed. Post it straight to the dispatcher on igpu to keep nginx out of it:

```bash
scp long-recording.m4a igpu:/tmp/t.m4a
ssh igpu 'curl -s --max-time 3600 -X POST \
  http://127.0.0.1:9875/v1/audio/transcriptions \
  -F "file=@/tmp/t.m4a" -F "model=large" -F "response_format=json"; rm -f /tmp/t.m4a' \
  | jq -r .text > out.txt
```

Pass criteria:

1. **No loop** — `sort out.txt | uniq -c | sort -rn | head` shows no line
   repeated many times over.
2. **Punctuation survives** — `grep -c '^ *[A-Z]' out.txt` is a healthy fraction
   of total lines, not near zero.
3. **Short clips still work** — send a 15–25s clip too. VAD must not swallow
   brief input, because the Dictate phone keyboard depends on this same endpoint.

## When to revisit

- If transcripts start **losing** speech rather than looping, `vad.threshold` is
  too high for the input. Car-cabin audio has a continuous noise floor, so lower
  before raising.
- If loops reappear on very long recordings, lower
  `vad.maxSpeechDurationSeconds` below 30.
- `--no-fallback` was deliberately **not** added. Temperature fallback exists to
  recover bad decodes, and VAD alone was sufficient. Try it only if punctuation
  inconsistency returns with VAD enabled.
