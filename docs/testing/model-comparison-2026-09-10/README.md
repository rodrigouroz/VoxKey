# Local speech models and Spanish grammar qualification

Measured on September 10, 2026. The app now offers compact/full Distil-v3 and
compact/full Whisper v3 Turbo, with language explanations and persistent selection.
The English default is unchanged. Distil-v3.5 was converted and benchmarked locally;
it is not a downloadable chooser option because a distributable VoxKey package has
not been prepared. Spanish grammar correction is excluded.

## Which model to try

| Candidate | Languages | Package size | English WER / median decode | Spanish WER / median decode | Tradeoff in this experiment |
| --- | --- | ---: | ---: | ---: | --- |
| Distil-v3 compact | English | 594 MB | 0.94% / 282 ms | — | Smallest download; rendered “queue” as “Q” in one clip. |
| Distil-v3 full | English | 1.51 GB | 0.00% / 275 ms | — | All words matched this small synthetic sample; larger download, with no personal-voice accuracy guarantee. |
| Turbo compact | Multilingual, including Spanish | 627 MB | 0.94% / 530 ms | 5.66% / 518 ms | Small bilingual download; slower here, with slightly lower Spanish WER than full Turbo. |
| Turbo full | Multilingual, including Spanish | 1.62 GB | 0.94% / 282 ms | 6.60% / 302 ms | Good first bilingual speed candidate; larger download and no demonstrated Spanish accuracy advantage. |
| Distil-v3.5 full, local conversion | English | 1.53 GB | 0.00% / 309 ms | — | Matched full v3's words; no demonstrated gain on this sample, and requires local conversion. |

These are explicit-language results. The [complete table](table.md) also includes
automatic detection and p95. Automatic detection identified the intended language
in every final warm sample. Its WER matched explicit selection in this experiment;
that is not a guarantee for short, noisy, or mixed-language speech.
Language coverage follows the upstream [Distil-v3](https://huggingface.co/distil-whisper/distil-large-v3)
and [Turbo](https://huggingface.co/openai/whisper-large-v3-turbo) model descriptions.

Use the chooser to compare models with your own voice. Zero WER in a small
synthetic sample does not establish an improvement for everyday dictation.
The timing difference between compact and full Distil is too small to treat as a durable speed ranking. A compact package
does not necessarily decode faster. The Spanish difference between
Turbo variants is one word per 106 reference words, repeated over two warm rounds.
It is not evidence of a general accuracy winner.

Both Turbo variants omitted the initial “The” in one English clip. Spanish
mismatches mostly involve accents and voseo forms such as `revisá`/`revisa`,
`avisame`/`avísame`, and `podés`/`puedes`. The voices are Mexican and European Spanish,
not Argentine speakers; their pronunciation of voseo is a confound. See the exact
[mismatches](differences.json) before interpreting WER as recognition quality.

## Method and limits

- Release builds use Argmax OSS/WhisperKit 1.1.0 and Core ML `.all` compute units.
  Public dependency revisions are pinned in the repository lockfile.
- Sixteen synthetic clips: four texts per language, each read by two installed
  macOS voices. Exact voice names are Samantha, Daniel, Paulina, and Mónica.
  Their names are checked before synthesis. [Manifest](manifest.json) records
  references, voice names, package revisions, and audio SHA-256 values.
- Every candidate runs in a separate process. Three rounds per applicable clip;
  round zero is excluded from warm metrics. Turbo runs explicit and automatic
  language selection. Total: 264 decodes, including 176 warm observations.
  Repeats are timing observations, not additional independent speech examples.
- Candidates were measured sequentially on the same device, without overlapping
  conversion, inference, or build jobs from this experiment. Timings are comparative
  observations, not performance promises for other hardware. Machine inventory,
  system settings, local paths, and personal dictation are excluded from this report.
- Inference matches the app's phrase decoder settings. Grammar correction,
  vocabulary hints, and preceding-phrase prompts are absent. The test measures
  decoding of completed clips, not key-release-to-editor latency or a live
  microphone session. Loading is logged separately, with warmed system caches;
  it is not a clean-machine startup measurement. Runtime memory was not measured.
- WER uses Unicode NFC and case folding; punctuation is ignored, accents count,
  and written/spoken number variants are not equated. Each language/mode has eight
  clips, 106 reference words, and two measured rounds. p95 of 16 observations is
  effectively the slowest observation and is not a stable tail-latency estimate.

The app's separate real-inference acceptance test passed Spanish and automatic
detection through both batch and streaming `WhisperTranscriber`, and confirmed a
failed replacement leaves the previous model usable. All 233 app tests passed after the 0.3.0 design integration.
The chooser was rendered and inspected in light and dark appearances. Physical
microphone, editor delivery, Argentine pronunciation, long speech, and other
Whisper languages still need personal acceptance testing.

Reproduction commands and opt-in test instructions are in
[scripts/models](../../../scripts/models/README.md). Raw `.jsonl` files beside this
report contain only generated reference text and its model output. Audio and model
weights remain in the ignored local `.build/whisper-comparison` directory.

## Distil-v3.5 conversion provenance

The [official model](https://huggingface.co/distil-whisper/distil-large-v3.5) is
English-only. The pinned Argmax catalog did not contain a ready conversion.
Local conversion used `argmaxinc/whisperkittools` commit
`84f77a83c8f530022ae55fbb1a64b3351ef63c7a` with official model revision
`728a7691f3ff1d3d971528d3203a6e9559165d41`, in an isolated Python 3.11 environment
with PyTorch 2.5.0 and Transformers 4.53.0. Compute units were set to `.ALL`, as in
the app. No upload was performed and no conversion correctness checks were disabled.

Both decoder checks and all three encoder/mel checks passed. Recorded conversion
PSNR was 58.9 dB for the decoder, 76.4 dB for the encoder, and 74.1 dB for the mel
component. The three compiled components and source `config.json` and
`generation_config.json` were used by the same Swift harness as the other models.
These checks establish this local conversion's tested behavior; they do not provide
a distributable package or a general quality qualification.

## Spanish grammar: do not include

The inclusion bar is both credible independent comments/reviews and strong local
quality/speed results. None of the candidates investigated met both requirements.

| Candidate | Supporting evidence | Local result / decision |
| --- | --- | --- |
| SkitCon Spanish BETO token corrector | The [author's model card](https://huggingface.co/SkitCon/gec-spanish-BETO-TOKEN-COWS-L2H) explicitly reports unreliable word replacements and failures on more complex grammar. | Not advanced to integration or timing tests. Requires custom decoding and does not stand out on reliability evidence. |
| dreuxx26 multilingual mT5-small | Its [model card](https://huggingface.co/dreuxx26/Multilingual-grammar-Corrector-using-mT5-small) claims Spanish performance without a reproducible evaluation protocol. The [single public discussion](https://huggingface.co/dreuxx26/Multilingual-grammar-Corrector-using-mT5-small/discussions/1) contained no substantive quality feedback when checked. | Tested locally: 0/5 complete corrections, 9/9 preservation cases. Excluded. |
| The same author's Mejora/ONNX follow-on | The [project README](https://github.com/dreuxx/Grammar-Checker-v2-BY-ML) describes work in progress and reports 32–35% Spanish exact match. This is author evidence, not independent validation. | No compelling evidence to justify another runtime/conversion or app integration in this change. |

mT5 qualification used pinned revision `1e7f08320a74dd0307101d31e8620acffffa51a9`,
standard safetensors weights, the original slow SentencePiece tokenizer, and the
author's plain-text generation approach with greedy decoding and 64 maximum new
tokens. Remote code was disabled and inference ran offline. The 14 fixtures were
curated before inference. Three rounds repeated the same examples; warm median
generation was **82 ms** on Python CPU with four threads. This is not a Core ML
production timing estimate. The [summary](spanish-grammar-summary.json) and
[raw outputs](spanish-grammar.jsonl) preserve the evidence.

Manual inspection confirmed the failed corrections were not valid alternatives:
`La niña están cansada.` stayed unchanged; `Los archivo está listo.` became
`Los archivos está listo.`, fixing only part of the agreement. The model also left
the verb, gender, and accent errors in the other three correction examples.
Negation, numbers, technical names, and Argentine voseo were preserved in the nine
already-correct cases. Good preservation alone is insufficient for a corrector.

Spanish dictation remains usable independently. The existing English corrector is
paused for Spanish, other non-English selections, and Automatic. Its saved user
preference is retained for returning to explicit English.
