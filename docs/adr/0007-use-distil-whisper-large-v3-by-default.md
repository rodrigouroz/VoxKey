---
status: accepted
---

# Use Distil-Whisper large-v3 by default

VoxKey uses the 594 MB compressed Core ML conversion of the English-only Distil-Whisper large-v3 model as its Default Model. It offers a mature Whisper lineage and published near-large-v3 accuracy with substantially lower latency, while avoiding the multilingual capacity of the prototype's large-v3-turbo model. Its published LibriSpeech result is modestly worse than the full 1.51 GB conversion, but the smaller storage and resident-resource footprint better fits an Always Ready background utility.

The model chooser offers the full 1.51 GB Distil-Whisper large-v3 conversion and
the compact 627 MB and full 1.62 GB Whisper large-v3-turbo conversions. All choices
use the same WhisperKit and Core ML inference path. Turbo supports multilingual
transcription, including Spanish; Distil-v3 is English-only. The chooser discloses
language coverage and size before explicit activation, and remembers the model
and language only after the replacement warms successfully. Preparation pauses
dictation; failed replacement preserves the previous working configuration.

Automatic language detection is available on multilingual models. The current
English grammar corrector is enabled only for explicit English sessions; a
Spanish or multilingual corrector needs separate quality and latency qualification.
Distil-v3.5 remains a benchmark candidate until a distributable Core ML package
is available. Parakeet would introduce a second runtime and remains deferred.
VoxKey never switches models automatically or introduces a cloud fallback.
