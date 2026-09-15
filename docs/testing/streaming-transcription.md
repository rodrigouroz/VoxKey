# Streaming transcription

VoxKey uses WhisperKit 1.1.0 with the existing compressed Distil-Whisper model.
Recognition runs on completed acoustic phrases during capture. A bounded tail of
completed text and provisional decoder text is published to the Status Overlay; the Destination receives only
the Final Result. The preview contains at most 1,200 characters, shows the latest
three lines, and is cleared when the session ends. Progress is awaited so the
last phrase reaches session state before finalization continues. Stale-session
and cancellation callbacks cannot restore cleared text.
Speculative decoding starts after at least one second of unfinished speech, then
at most once every 700 ms with at least half a second of new audio. It uses a copy
of the latest eight seconds, caps output at 128 tokens, and disables fallback
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

## Validation limits

Synthetic fixtures do not establish accuracy, latency percentiles, or microphone
compatibility. Test quiet and soft speech, noise, accents, sentence pauses, long
uninterrupted speech, and both supported model choices on the candidate Mac.
Vocabulary prompts add decoding work. Streaming shifts inference into capture;
battery and thermal behavior require separate measurements. See the
[compatibility checklist](../release/core-compatibility-checklist.md).
