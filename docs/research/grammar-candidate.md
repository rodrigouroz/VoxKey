# Local grammar correction

Available in Beta 4 and later, optional grammar correction uses GECToR RoBERTa-base with Core ML FP16 with CPU/GPU execution. Whisper allows all Core ML
compute units, including the GPU. Its model files are downloaded on explicit opt-in. The runtime,
installer and FP16 preparation are native Swift/Core ML; users need no server,
Python, Homebrew, or separately installed runtime.

## User behavior

- **Correct grammar locally** defaults off, appears during onboarding and in
  Settings, and persists across launches. Off performs no model download or
  inference. Disabling cancels active preparation and unloads correction data.
- Enabling permits a **519 MB** download from the model author and original
  vocabulary repository. The original checkpoint is only available in FP32;
  the app converts it to the qualified FP16 representation locally. Installed
  model, tokenizer and vocabulary occupy approximately **263 MB**.
- Progress and preparation status appear in both locations and explicitly say
  dictation continues without correction. Downloading and preparing the optional
  model never gate transcription readiness or wait for installation before
  delivering a transcript. Interrupted or failed setup also leaves ordinary
  dictation working, with a retry action.
  Completed files are reused on retry; an interrupted individual file restarts.
- Once preparation finishes, the already-enabled corrector automatically uses
  the model for subsequent transcription results, without a restart or another
  toggle. Previously delivered text is not revisited. Correction then works
  offline. Restarting with the preference
  on reuses an installed model; missing files require another explicit download
  action. Recording starts background Core ML loading/optimization when the assets are ready.
- A bounded correction worker processes committed transcription during recording.
  It coalesces pending updates and retains only the current chunk plan. Finalization
  reuses a correction only when its complete model input matches exactly; changed
  context is corrected again. Whisper always receives uncorrected context.
  Delivery and Safety Net storage remain atomic, after the final result, with the
  existing destination validation. Enabling applies to new sessions; disabling
  invalidates pending and cached correction. Cancellation discards session work.
- Short inputs keep their qualified whole-text context. Longer text is split at
  sentence boundaries, or word boundaries within oversized sentences, to fit
  80 RoBERTa tokens including special tokens. Paragraph separators are preserved.
  Unusual spacing within a chunk and unbroken words exceeding the limit remain
  unchanged; other chunks can still be corrected. Reserved model markers preserve
  the whole transcript. Five edit iterations per chunk is the maximum.
  Installation and inference errors retain the original. Audio, surrounding field context and transcript text are
  never sent to the download hosts or written to diagnostics.

## Combined performance and long dictations

See [transcription and correction scheduling](inference-performance.md) for the
processor selection and bounded background worker.

Sentence boundaries can change grammar-model behavior. In the long-text tests,
repeated “The build is ready.” became “The building is ready.” Short-input parity
and successful chunk assembly do not establish meaning preservation for long
text. Packing more sentences together also changed qualified outputs, so the
implementation retains sentence boundaries and its opt-in “may change words” notice.

## Download and conversion integrity

`Sources/VoxKeyApp/Resources/GrammarPreparation/recipe.json` pins URLs, sizes,
SHA-256 hashes, source tensor offsets and the output weight hash. It uses:

- `gotutiyan/gector-roberta-base-5k` revision
  `adaac6fb919431fb5a038b1e449055ae638613a4`, fetched from Hugging Face.
- The verb vocabulary from `grammarly/gector` revision
  `3d41d2841512d2690cffce1b5ac6795fe9a0a5dd`, fetched from GitHub.

The four files total **518,438,654 bytes**. Each must match its pinned size/hash.
The model's tensor offsets are used only after validating the entire source.
The recipe reconstructs 200 FP16 tensor segments, including the repeated token
embedding. Small format headers/padding and the configured keep bias are
retained as constants. The reconstructed weight blob must have SHA-256
`3b39288c1b69d4011b4d398314a075f8e8f5f1518a097899f874e4e058b89690`, exactly matching
our qualified Core ML artifact. Core ML compiles the prepared package locally;
only a completed installation with a recipe receipt is activated.

The app ships approximately 216 KB of preparation resources instead of the
large weight files. The source checkpoint is removed after successful setup.
Interrupted setup cannot activate partial assets. The default model cache is
`~/Library/Application Support/com.rodrigouroz.VoxKey/Models`, excluded from
backup. The native BPE tokenizer stays separate from Whisper's tokenizer.

## Licensing

VoxKey source remains MIT. The grammar model, converted model definition,
tokenizer and vocabulary retain their separate terms. The checkpoint card says
**Only non-commercial purposes** and does not give a standard license or explicit
redistribution grant. Downloading from the author avoids hosting the checkpoint
ourselves; it does not remove its use restriction. Beta 4 exposes grammar correction as an optional, initially disabled feature
for noncommercial use. The model remains separately licensed from VoxKey.
The original model card, reference-code MIT license and vocabulary's Apache 2.0
license are bundled. See [terms](../../licenses/grammar/TERMS.md).

## Build and verify

```sh
swift test --force-resolved-versions --no-parallel
VOXKEY_SIGNING_IDENTITY=- ./scripts/build-app.sh release preview
```

`VOXKEY_GRAMMAR_ASSETS` is obsolete and explicitly rejected. The build no longer
copies model files into the application. A fresh HTTP installation test is
explicitly opt-in and downloads 519 MB; use a new empty directory to test the
network path rather than cache reuse:

```sh
VOXKEY_GRAMMAR_INSTALL_TEST_ROOT="$PWD/.build/grammar-http-check" \
  swift test -c release --force-resolved-versions --no-parallel \
  --filter authorDownloadPreparesExactFP16WeightsAndWorksOffline
```

For already prepared assets, set `VOXKEY_GRAMMAR_TEST_ASSETS` to the installed
version directory and run the normal suite. The suite checks all 64 expected
GPU/all-compute outputs and token IDs, length fallback and unloading. Ordinary
tests download no models. HTTP-error, size-limit and cancellation tests simulate
only the external URLSession boundary and use the real transfer/store logic.

To reproduce the preparation resources, use the pinned
[model build tools](../../scripts/grammar-model/README.md). Generated checkpoints,
compiled models, and local test reports belong in `.build/`.

For a manual check, launch the packaging preview, enable **Correct grammar
locally**, wait for preparation, and compare dictation with correction off and
on. The preview uses its own bundle identifier and preferences. Automated model
checks do not establish microphone-to-editor compatibility for every app.
