# Improve transcription

Enable **Improve transcription** in Settings → Dictation to remove fillers and
repetitions and improve English grammar after speaking. The setting defaults off,
including for users of the previous grammar-only option. Models download only on
opt-in (up to 2.03 GB); valid installed assets are reused. Processing stays on the Mac.

The final pipeline is Whisper → S1-mini with prompt lookup → restricted GECToR edits.
llama.cpp is linked directly with Metal support; no server, Python, or Homebrew is
required. Guards protect technical literals and limit grammar-stage word substitutions.
Failed, cancelled, unsupported, or oversized requests preserve raw recognition.
Disabling the setting restores raw transcription. Improvement currently requires
English; Spanish, other languages, and automatic detection still support dictation.

S1-mini is by Superwhisper. The GECToR model is for noncommercial use. See the
[bundled notices](../THIRD_PARTY_NOTICES.md) and model licenses before enabling it.

## Final validation results

On one Apple Silicon Mac, 124 natural-speech inputs produced identical text and
output tokens with native plain decoding and prompt lookup (248 comparisons).
Median S1 time fell from 362 ms to 121 ms, with a 2.71× reduction in aggregate time.
The complete guarded pipeline matched all 124 qualified outputs using the signed
bundled framework, measuring 128 ms median and 431 ms p95. These are warm editing
times and exclude recognition, startup, and text delivery. Guard decisions also
matched 388 frozen cases. These measurements are limited validation, not a universal
latency or accuracy guarantee.

Regression coverage includes real-model lookup parity, cancellation and recovery,
corrupt downloads, opt-in behavior, preservation guards, and local-debug trace consent.
Models can still alter names, meanings, or spoken corrections. Review important text.

Release and release-candidate binaries contain no VoxKey trace recorder or diagnostic
controls. Developer diagnostics require an explicit local Debug build; see
[the build instructions](release/distribution.md#diagnostic-boundary).
