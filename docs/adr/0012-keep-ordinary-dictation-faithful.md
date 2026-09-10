---
status: accepted
---

# Keep ordinary dictation faithful

Ordinary VoxKey dictation preserves the speaker's words and meaning. It may apply deterministic Dictation Mechanics needed to integrate text into an unchanged Editing Intent, but it does not silently remove fillers, paraphrase, summarize, or change tone. Any future semantic Polish capability must be an explicit, visibly separate, local-only action. This keeps the consequence of the trigger predictable and prevents a writing model from being mistaken for transcription.

Beta 4 promotes the September 2026 grammar-correction candidate as an explicit exception:
users can opt into a local grammar edit pass during onboarding or in Settings.
It defaults off, discloses the extra processing and possible word changes, and
leaves the original transcription intact on failure or unsupported input.
This permission does not enable general paraphrasing, summarization, or tone
changes. The opt-in beta feature accepts the measured FP16 Core ML quality difference
documented in `docs/research/grammar-candidate.md`.
