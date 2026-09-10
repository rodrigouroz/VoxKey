# Third-party notices

VoxKey's source code is MIT licensed. This does not relicense third-party model
weights, tokenizers, or vocabulary data. Its app bundle includes the original license texts for
these Swift Package Manager dependencies in `Contents/Resources/Licenses`:

| Dependency | License | Source |
| --- | --- | --- |
| Argmax OSS (WhisperKit and ArgmaxCore) | MIT; vendored swift-transformers portions under Apache 2.0 | https://github.com/argmaxinc/argmax-oss-swift |
| ZIPFoundation | MIT | https://github.com/weichsel/ZIPFoundation |
| Sparkle | MIT and bundled third-party notices | https://github.com/sparkle-project/Sparkle |
| swift-argument-parser | Apache 2.0 with Swift Runtime Library Exception | https://github.com/apple/swift-argument-parser |

Exact source revisions are recorded in `Package.resolved`. The build copies license
texts from those resolved checkouts. When adding a dependency, update this list and
the license-copy step in `scripts/build-app.sh`, including any upstream NOTICE file.
Argmax OSS vendors the tokenizer and model-download code previously supplied by
swift-transformers; its full `NOTICES` file is included as `ArgmaxOSS-NOTICES.txt`.
Only WhisperKit and ArgmaxCore are linked; VoxKey does not add speech synthesis
or speaker diarization.

Transcription model weights are downloaded separately during setup and are not
bundled in the app or DMG. The current transcription model is distributed through
[argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml),
derived from [Distil-Whisper](https://huggingface.co/distil-whisper/distil-large-v3)
and [OpenAI Whisper Turbo](https://huggingface.co/openai/whisper-large-v3-turbo).
Consult those model cards for their terms and attribution.

VoxKey offers an opt-in download of the GECToR
RoBERTa-base checkpoint and tokenizer from the author, plus the GECToR verb
vocabulary from its original repository. VoxKey prepares the FP16 weights locally
using Core ML and a small bundled conversion recipe and model definition; the
large model files are not bundled or hosted by VoxKey. The checkpoint is marked
**noncommercial-only**, with no explicit redistribution grant. These third-party
assets and the converted model definition are excluded from VoxKey's MIT license.
See [the exact terms and attribution](licenses/grammar/TERMS.md).
App bundles include these terms and the original upstream texts under
`Contents/Resources/Licenses/Grammar`. The reference decoder code is MIT and the
verb vocabulary's source repository is Apache 2.0; neither code license grants
additional rights to the trained weights.

The bundled capture cues are synthesized tones created for VoxKey. No Star Trek
recording or other downloaded sound effect is included.
