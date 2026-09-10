---
status: accepted
---

# Never persist dictation audio

VoxKey never writes dictation audio to persistent storage, including when transcription fails. Audio may exist only in volatile memory for the duration of capture and transcription. This prioritizes a simple, auditable privacy guarantee over crash recovery and transcription retry; a failed transcription therefore loses the utterance, while non-content diagnostic metadata may still be retained.
