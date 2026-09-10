# Local Whisper comparison

This experiment uses only generated speech. It never records the microphone or
uploads audio, references, or results. Downloads go into `.build/whisper-comparison`;
the app's active model and preferences are not changed.

```sh
python3 scripts/models/prepare-comparison.py --download
swift test -c release --force-resolved-versions --no-parallel --filter compareWhisperCandidate
```

The first command pins the Argmax model catalog revision in `argmax-index.json`,
downloads the baseline and three alternatives (about 4.4 GB total), and creates
16 fixtures with installed macOS voices: Samantha, Daniel, Paulina, and Mónica.
Exact voice names are validated, including Mónica's accent, to prevent silent
voice fallback. Empty synthesis output is rejected.
English and Spanish each have a short sentence, a grammar/word-preservation or
voseo example, a negation/repetition example, and technical terms. No voice assets
are downloaded by this script. Keep the fixtures unchanged across model runs.

After compilation and other heavy work have finished, run one model at a time:

`python3 scripts/models/run-comparison.py` builds release tests, runs every model in
the manifest sequentially, and summarizes the results. Use `--models` to select candidates. For a single already-built run:

```sh
VOXKEY_MODEL_COMPARISON="$PWD/.build/whisper-comparison" \
VOXKEY_COMPARISON_MODEL=turbo-compressed \
swift test -c release --skip-build --no-parallel --filter compareWhisperCandidate
```

Repeat with `distil-v3-compressed`, `distil-v3-full`, and `turbo-full`. The harness
reads the exact folder, language coverage, and revision from `manifest.json`.
Each process loads one model and records loading separately from inference.
Three rounds are recorded; the summary excludes round zero. Turbo runs both
explicit language selection and automatic detection. Distil runs English only.
Inference uses the production phrase decoder's settings and `.all` Core ML
processors, with grammar, vocabulary, and previous-phrase context absent.

```sh
python3 scripts/models/summarize-comparison.py
```

`summary.json` and `table.md` contain aggregate word error rates, median and p95
decode time. `differences.json` retains mismatched synthetic examples. WER uses
Unicode NFC, case folding, and letter/number tokens. Accents remain significant;
punctuation and case are ignored, but numeric spellings are not equated. This is
a small synthetic regression sample, not a general accent or dictation benchmark.
Model download size is not runtime memory. Decode time is not key-release-to-editor
latency. Keep hardware inventory, system settings, local paths, logs, and personal
dictation out of published results. Machine metadata is not collected by the harness.

## Production path acceptance

```sh
VOXKEY_MULTILINGUAL_TEST_ROOT="$PWD/.build/whisper-comparison" \
swift test --force-resolved-versions --no-parallel \
  --filter installedTurboTranscribesSpanishInBothPathsAndPreservesItsModelAfterFailedSwitch
```

This uses real Core ML inference through `WhisperTranscriber`, including both
batch and streaming paths, Spanish and automatic detection, and a failed model
replacement. Synthetic input enters the real audio capture boundary; no physical
microphone or editor is exercised. It also confirms Spanish words are transcribed
rather than translated into English.

## Distil-v3.5

Argmax's standard catalog does not currently include this model. The local
research conversion uses `argmaxinc/whisperkittools` in an isolated Python 3.11
environment and the official `distil-whisper/distil-large-v3.5` weights. Conversion
must not set `--upload-results`. Use `argmaxtools.test_utils.TEST_COMPUTE_UNIT =
coremltools.ComputeUnit.ALL` to match VoxKey. Keep upstream conversion checks enabled and inspect
their results, since the generator can finish without propagating test failures.
Add a local manifest entry only after all three compiled model components and
source configuration files are present. The report records conversion provenance
and any compatibility limitations. This does not install a distributable app model.

To include a completed conversion when preparing a new manifest, supply
`--distil-v35 /absolute/path/to/converted/model --distil-v35-revision SOURCE_COMMIT`
to `prepare-comparison.py`. This checks required components; the caller must
inspect the conversion test results. Preparation regenerates synthetic audio, so
do it before all comparisons, never between candidates in one comparison.

## Spanish grammar qualification

`qualify-spanish-grammar.py` is an isolated research screen for a pinned mT5-small
candidate. It is not imported by VoxKey. In a separate Python environment with
PyTorch, Transformers, Hugging Face Hub, and SentencePiece installed, run:

```sh
python scripts/models/qualify-spanish-grammar.py --download-only
python scripts/models/qualify-spanish-grammar.py
```

Download uses only standard configuration, tokenizer, and safetensors weights;
inference is offline and remote model code is disabled. Fourteen curated Spanish
sentences cover five corrections and nine preservation cases, including voseo,
negation, identifiers, and numbers. Three rounds are recorded, with round zero
excluded from warm timing. Exact matching is a strict screening metric and needs
manual output inspection for valid alternatives. Timings use Python CPU inference
with four threads, not the app's Core ML pipeline. A candidate also needs credible
independent feedback before it can qualify for app integration.
