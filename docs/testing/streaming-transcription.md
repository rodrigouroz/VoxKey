# Streaming transcription

VoxKey uses WhisperKit 1.1.0 with the existing compressed Distil-Whisper model.
Recognition runs on completed acoustic phrases during capture; partial text is never displayed or inserted.
Completed phrases are retained, the unfinished tail stays as audio, and release
closes capture, drains every remaining sample, flushes resampling, and returns one
Final Result through the existing delivery checks and Safety Net.

## Boundaries and earlier predictions

- One session task serializes capture reads, resampling, and inference. Cancellation
  stops the microphone and awaits the worker before another session can use the model.
- A persistent AVAudioConverter preserves filter state across input chunks. Audio
  reaches the model as 16 kHz mono floats without intermediate files.
- Open phrases are not decoded speculatively. These predictions cannot retire
  audio and are not displayed; a release during speculation would otherwise wait
  for that pass and then a second pass with the final samples.
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

## Validation limits

Synthetic fixtures do not establish accuracy, latency percentiles, or microphone
compatibility. Test quiet and soft speech, noise, accents, sentence pauses, long
uninterrupted speech, and both supported model choices on the candidate Mac.
Vocabulary prompts add decoding work. Streaming shifts inference into capture;
battery and thermal behavior require separate measurements. See the
[compatibility checklist](../release/core-compatibility-checklist.md).
