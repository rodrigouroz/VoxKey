# Transcription and correction scheduling

Whisper allows all Core ML compute units. Optional GECToR correction uses
CPU/GPU, with a bounded worker during recording. Core ML chooses the actual
processor placement; allowing a device does not guarantee its use on every Mac.

The correction worker starts model loading when recording begins, receives only
committed raw transcription, and replaces obsolete pending updates. Its cache
holds the current chunk plan for one dictation. At release it reuses a correction
only when the complete model input matches; changed context is corrected again.
Whisper always receives uncorrected context. Delivery happens once, after the
final result, with the usual destination checks.

Short inputs retain whole-text context. Longer text splits at sentence boundaries,
then word boundaries to fit 80 tokens. Combining unrelated short inputs into a
larger batch changed meaning in qualification, including reversing a negation.
The implementation therefore retains sentence boundaries even when larger
batches would reduce model calls. Five edit iterations per chunk is the maximum.

## Quality limits

The regression corpus covers 64 synthetic inputs and their expected token IDs
and outputs. It is a compatibility check, not an estimate of universal grammar
accuracy. Sentence-level correction can still change meaning: repeated
“The build is ready.” became “The building is ready.” in long-text checks.
Correction remains optional, defaults off, and warns that words may change.
Errors preserve the original text; disabling invalidates pending and cached work.

## Validation

[The model guide](grammar-candidate.md#build-and-verify) explains how to run the
native corpus against installed assets. `InferencePerformanceTests.swift` also
contains opt-in combined inference and real-time streaming checks. Supply only
synthetic audio, keep generated logs in `.build/`, and record hardware, power
mode, cache state, and input duration when comparing runs. Model-call timings
alone do not measure key-release-to-editor latency or battery consumption.
