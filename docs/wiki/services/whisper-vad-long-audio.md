# Whisper VAD for long-form audio

Date: 2026-09-10
Status: **deployed to igpu and verified end-to-end** on 2026-09-10 against two
real car recordings (16m49s and 5m04s) plus a 25s short clip. Results below.
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

### Correction (2026-09-11): chunk size was probably not the cause

The table above is accurate about *what happened*, but the original conclusion
— that chunk **size** drove the all-lowercase, unpunctuated output — is likely
wrong. Later work on a different recording found a better explanation:

- Whisper drops into that lowercase/unpunctuated mode on stretches of **low
  local SNR**. A minute measured at 6.4 dB SNR produced exactly it; a minute of
  the same recording at 20.3 dB did not.
- The chunks that came back degraded were most likely the ones containing poor
  audio, not the ones that happened to be long.

There is a second trap here. Cutting that bad minute out and transcribing it
**alone** reproduced the degraded output — but the same audio inside the
full-file VAD run transcribed correctly, punctuation and all. **An excerpt is
not a faithful test of how the pipeline handles that audio.** Compare whole
files, or you will chase a defect the real path does not have.

None of this changes the fix: VAD solves the loop, and chunking remains the
wrong tool. It changes what to blame when punctuation degrades — look at the
audio's local SNR, not at segment length.

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

## Verified results (2026-09-10)

| | 16m49s drive | 5m04s | 25s clip |
|---|---|---|---|
| time | 230s | 64s | 6s |
| words | 2562 | 697 | 16 |
| lines capitalised | 240/344 | 68/99 | 1/2 |
| lines punctuated | 231/344 | 67/99 | 1/2 |
| max repeated line | 2 | 1 | 1 |

Against the pre-VAD baseline for the same 16m49s recording (453 lines, 2934
words): `And then, uh.` went **15 → 0**, `photo of dad` went **11 → 1**, and the
tail now ends naturally on "See you later." instead of 36 lines of stutter.

**The 25s clip is the guard against fixing this by breaking something else.**
The Dictate phone keyboard posts 1–3s clips to this same endpoint, so VAD
swallowing short input would be a regression. It transcribed correctly.

### Word count dropped — that is expected, not lost speech

2934 → 2562 words looks alarming. It is not content loss; it is whisper no
longer hallucinating filler over non-speech audio:

| filler | pre-VAD | post-VAD |
|---|---|---|
| `Um.` | 1 | 0 |
| `Yeah.` | 8 | 0 |
| `And, uh.` | 2 | 0 |
| `And then, uh.` | 15 | 0 |

Content was checked term-by-term and survives: Harriet 5→5, Churchview 2→2,
Stirlings 1→1, Langtons 1→1, Stu 11→11, barrel 5→5, margin 6→6.

**Beware spelling drift when checking this way.** Two names appeared to vanish
(Vanya 9→0, Galinda 3→0) but the passage was fully intact — whisper had spelled
them "Vania" and "Glinda" on the second run. Proper nouns it has never seen are
guesses and will vary between runs, so grep for the *surrounding passage*, not
the name, before concluding anything is missing.

### VAD is also faster

230s vs 343s for the same recording — about 33% quicker, because non-speech is
never fed to the decoder. Roughly 4.4× realtime, up from 3.5×.

## When to revisit

- If transcripts start **losing** speech rather than looping, `vad.threshold` is
  too high for the input. Car-cabin audio has a continuous noise floor, so lower
  before raising.
- If loops reappear on very long recordings, lower
  `vad.maxSpeechDurationSeconds` below 30.
- `--no-fallback` was deliberately **not** added. Temperature fallback exists to
  recover bad decodes, and VAD alone was sufficient. Try it only if punctuation
  inconsistency returns with VAD enabled.
