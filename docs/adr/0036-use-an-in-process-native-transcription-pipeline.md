---
status: accepted
---

# Use an in-process native transcription pipeline

VoxKey captures audio and runs WhisperKit and Core ML entirely inside the application process. The pipeline passes audio through bounded volatile buffers and never invokes whisper.cpp or another command-line model runner, encodes an intermediate recording, or writes a temporary audio file.

This rejects Yorick's external transcription backend. Yorick remains a reference for focus safety, recovery, onboarding, signing, and update code that may be ported selectively when it fits the Clean Rewrite. It also removes FluidAudio from the Core Release because both supported Distil-Whisper models share one WhisperKit and Core ML path.

The pipeline must use low-copy buffers, explicit backpressure, cancellation propagation, and one owner for each mutable session resource. Provisional Decode may reduce post-release latency, but only one reconciled Final Result can leave the transcription boundary. Performance claims come from profiling and real dogfood evidence on Supported Macs, not from assuming that an API or model is fastest by reputation.
