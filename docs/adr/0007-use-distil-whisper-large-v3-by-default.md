---
status: accepted
---

# Use Distil-Whisper large-v3 by default

VoxKey uses the 594 MB compressed Core ML conversion of the English-only Distil-Whisper large-v3 model as its Default Model. It offers a mature Whisper lineage and published near-large-v3 accuracy with substantially lower latency, while avoiding the multilingual capacity of the prototype's large-v3-turbo model. Its published LibriSpeech result is modestly worse than the full 1.51 GB conversion, but the smaller storage and resident-resource footprint better fits an Always Ready background utility.

The Core Release offers the full 1.51 GB Distil-Whisper large-v3 conversion as the only Model Override. Both choices use the same WhisperKit and Core ML inference path, vocabulary behavior, segmentation contract, and failure handling. Supporting Parakeet TDT v2 would introduce a second inference runtime before the core experience is proven, so it is deferred rather than bundled and hidden. VoxKey never switches models automatically or introduces a cloud fallback.
