# Streaming transcription

VoxKey uses WhisperKit 1.1.0 with the existing compressed Distil-Whisper model.
Recognition runs on completed acoustic phrases during capture. A bounded tail of
completed text and provisional decoder text is published to the Status Overlay; the Destination receives only
the Final Result. The preview contains at most 1,200 characters, shows the latest
three lines, and is cleared when the session ends. Progress is awaited so the
last phrase reaches session state before finalization continues. Stale-session
and cancellation callbacks cannot restore cleared text.
Speculative decoding starts after at least one second of unfinished speech, then
at most once every 700 ms. Each request requires fresh audio equal to at least a
quarter of its window (and at least half a second). This preserves the early
preview while moving toward one request per two seconds for an eight-second
window, bounding continuous-speech preview audio to four times captured audio.
A detected pause gets one catch-up preview outside that budget: after at least
200 ms of detected speech followed by 300 ms below the preview speech threshold,
show the latest words without waiting for the normal fresh-audio quota.
The 700 ms minimum between starts still applies to catch-ups, preventing repeated
brief pauses from flooding inference. This also covers utterances shorter than one second. Continued quiet
does not repeat the catch-up; new speech rearms it. Pause detection continues
while a preview is busy. Multiple pending pauses coalesce into one request using
the newest audio, including speech that resumes before the decoder is available. The catch-up window ends
300 ms after the latest detected voice, so trailing quiet cannot push those
words out of the window. This is presentation only and never changes the stricter
authoritative phrase cuts. Both preview paths use up to the latest eight seconds, cap output at 128 tokens, and disable fallback
attempts for previews only. This adds inference work but never retires audio,
commits preview words, or supplies them as recognition context. The authoritative
phrase thresholds, decoding options, prompts, and final-output assembly remain
unchanged.
The display excludes vocabulary/context prompt tokens, orders detached callbacks
by preview revision, audio window, decoding attempt, and token count, and discards
callbacks after completion. Only the newest pending update is buffered.
Provisional words use a softer color and completed phrase text replaces them.
Completed phrases are retained, the unfinished tail stays as audio, and release
closes capture, drains every remaining sample, flushes resampling, and returns one
Final Result through the existing delivery checks and Safety Net.

## Boundaries and earlier predictions

- One session worker owns capture reads and resampling, and serializes model access. Cancellation
  stops the microphone and awaits the worker before another session can use the model.
- A persistent AVAudioConverter preserves filter state across input chunks. Audio
  reaches the model as 16 kHz mono floats without intermediate files.
- Only one speculative decode may run, with no queue of preview jobs. Capture
  continues draining while it runs. A completed phrase, release, or cancellation
  cancels the preview task, requests token-loop early stop, and awaits teardown
  before the shared model is reused. An in-flight Core ML operation cannot be
  preempted immediately. Speculative errors are discarded; final decoding still
  reports errors normally.
- Audio is retired at a measured pause: ten consecutive 20ms frames below RMS
  0.003, with at least two seconds of audio before the cut. The cut leaves 100ms
  of quiet audio on each side. Each sample belongs to exactly one completed phrase.
- Release decodes the entire remaining tail once, even if it includes pauses.
  The worker reads capture's latest state between completed phrases so release
  takes priority over scheduling more phrase cuts. A phrase decode already running
  is allowed to finish; its text remains useful and its audio is retired.
- Personal vocabulary keeps priority within WhisperKit's 111-token prompt budget.
  Up to 16 recent transcript tokens use the remaining space as context. This is a
  hint, not a forced prefix; earlier mistaken predictions cannot force later words.
- There is no extra endpoint-silence wait after release. `windowClipTime: 0` also
  ensures WhisperKit does not skip a short final audio window.

The five-second realtime ring and thirty-second pending capture queue both report
overflow instead of silently dropping speech. Completed phrase audio is released.
When there is no clear pause, unconfirmed audio is retained up to the ten-minute
session limit, plus one second for the last hardware buffer (about 38.5 MB at 16 kHz).
Long uninterrupted speech can therefore still have a longer finalization delay.

## Repeatable checks

Run `swift test --force-resolved-versions --no-parallel` for phrase boundaries,
resampling, release ordering, cancellation, prompt limits, and fresh-session behavior.
Installed-model tests are opt-in. For the short-sentence regression:

```sh
say -v Samantha -r 110 -o /tmp/voxkey-short-sentence.aiff 'Please send me the notes after the meeting.'
VOXKEY_SHORT_TEST_AUDIO=/tmp/voxkey-short-sentence.aiff \
swift test -c release --force-resolved-versions --no-parallel --filter installedWhisperModelFinalizesAShortSentenceWithOneDecode
```

The synthetic fixture must last between two and three seconds. That regression
checks one decode, complete expected text, and agreement with batch transcription.
Other tests cover continuous speech, pending pauses at release, completed-prefix
preservation, silent tails, and cancellation after a completed phrase.

For unfinished-speech and native-overlay acceptance (installed model only):

```sh
say -v Samantha -r 195 -o /tmp/voxkey-preview.aiff 'Please send me the notes after the meeting.'
VOXKEY_PREVIEW_TEST_AUDIO=/tmp/voxkey-preview.aiff \
swift test --force-resolved-versions --no-parallel --filter 'installedModel.*(Preview|Speculation|Overlay)'
```

For pauses followed by faster speech, generate a second, short fixture and set
`VOXKEY_PREVIEW_RESUME_TEST_AUDIO` alongside `VOXKEY_PREVIEW_TEST_AUDIO`:

```sh
say -v Samantha -r 270 -o /tmp/voxkey-fast-resume.aiff 'Then send the updated plan before Friday.'
VOXKEY_PREVIEW_TEST_AUDIO=/tmp/voxkey-preview.aiff \
VOXKEY_PREVIEW_RESUME_TEST_AUDIO=/tmp/voxkey-fast-resume.aiff \
VOXKEY_PREVIEW_TEST_MODEL=distil-whisper_distil-large-v3 \
swift test -c release --force-resolved-versions --no-parallel --filter installedModelPauseThenFastSpeech
```

Keep the two fixtures plus the longest pause below seven seconds. This checks
200, 400, and 1,200 ms pauses, complete preview words before release, and unchanged
final recognition. Deterministic scheduler tests also cover uneven capture
chunks, busy inference, repeated brief pauses, noise transients, and retirement
of a pending phrase. These are controlled fixtures, not a claim that every voice,
noise environment, or model has been validated.

The tests feed synthetic audio in 100 ms increments while capture remains open,
assert visible native overlay text before any committed phrase, compare final
text with previews disabled, and release/cancel during active speculative decoding.
A warmed local run on 2026-09-14 showed first words after 1.19–1.21 seconds and
release-to-result times of 187–194 ms with preview versus 209–213 ms without it.
The user's selected full-precision Distil model also passed: first words after
1.19–1.21 seconds, release-to-result 177–195 ms with preview versus 189–206 ms
without, and cancellation during an active preview in 4 ms. To test that model,
add `VOXKEY_PREVIEW_TEST_MODEL=distil-whisper_distil-large-v3` to the command.
These are small-fixture checks, not latency percentiles or evidence of a speedup.

For sustained-preview efficiency, set `VOXKEY_PREVIEW_BENCHMARK_AUDIO` to a longer
generated speech file and run `installedModelMeasuresSustainedPreviewWork` with
`-c release -Xswiftc -DVOXKEY_PERFORMANCE`. Set `VOXKEY_PREVIEW_TEST_MODEL` to the
installed model to compare. This feeds audio at microphone speed with previews
off/on, checks equal final text and early visible updates, and reports existing
performance counters without writing synthetic sessions into the user's reports.

A local optimized run on 2026-09-18 used 24.625 seconds of generated English
speech and full-precision Distil v3. The previous and adaptive schedules, before the pause catch-up addition, produced:

| Measurement | Previous | Adaptive |
|---|---:|---:|
| Speculative decodes | 33 | 17 |
| Audio submitted to previews | 182.02 s | 72.23 s |
| Total preview decode wall time | 8.82 s | 4.40 s |
| First visible words | 1.199 s | 1.189 s |
| Release to final result | 0.251 s | 0.241 s |
| Whole-session process CPU time | 5.83 s | 3.72 s |

Both versions returned the same final text as their previews-disabled run, with
three authoritative decodes. This is one paired synthetic fixture, not a latency,
accuracy, battery, or thermal guarantee. The deterministic continuous-audio
regression also reduced scheduled requests from 85 to 33 per minute and submitted
audio from 641.5 to 234.2 seconds, while leaving final audio intact. Live recording
with the performance build remains the real-workload acceptance check.

The pause catch-up regression on 2026-09-18 verified complete visible sentence
text before release with a synthetic 0.005 background level (above the stricter
phrase-cut threshold), unchanged final recognition, one catch-up per pause, and
no repeated work in silence. Short-speech capture/error handling, release, and
cancellation checks passed. The sustained fixture still used 17 speculative
decodes and 72.23 seconds of preview audio. The full suite was **not green**:
`animatedCaptionExpansionKeepsTextBelowTheStatus` failed its unchanged window-size
assertion (212×46 observed, 360×125 expected), including in isolation. Its source
and overlay animation code were not modified by this change. The pause overlay
regression disables animation; physical preview acceptance remains necessary.

The subsequent pause/resume hardening run on 2026-09-18 passed the complete
optimized measurement suite: 280 app, 16 core, and two audio-ring tests. The
previously failing animation test passed on this run without animation changes;
that observation does not establish the earlier failure's cause. A separate
installed full-precision Distil v3 run passed all three pause/fast-speech cases
(200, 400, and 1,200 ms). The continuous-audio schedule remained at 33 requests
and 234.2 seconds of submitted audio per minute. The new scheduler coalesces
busy-decoder pauses, includes resumed speech, and enforces the 700 ms start
interval for catch-ups too. Performance and delivery instrumentation remain on
in the local measurement bundle.

## Validation limits

Synthetic fixtures do not establish accuracy, latency percentiles, or microphone
compatibility. Test quiet and soft speech, noise, accents, sentence pauses, long
uninterrupted speech, and both supported model choices on the candidate Mac.
Vocabulary prompts add decoding work. Streaming shifts inference into capture;
battery and thermal behavior require separate measurements. See the
[compatibility checklist](../release/core-compatibility-checklist.md).
