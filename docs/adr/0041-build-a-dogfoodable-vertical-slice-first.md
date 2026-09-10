---
status: accepted
---

# Build a dogfoodable vertical slice first

The first VoxKey v2 milestone is one complete, dogfoodable path: Globe/Fn Hold to Dictate, Capture Cues, volatile capture from the System Input Device, the compressed Default Model through the Native Transcription Pipeline, one Final Result, capability-based Text Delivery into TextEdit and Notes, and the Safety Net when delivery cannot complete.

The slice includes the explicit session state machine, cancellation, No Speech handling, Secure Destination rejection, bounded Editing Context, and focused automated tests needed to trust that path. It may use development-only model installation while the public Model Package installer is not yet built, but it may not use a fake recognizer or special insertion path for acceptance.

Application updates, Vocabulary Package import, the full Model Override, broad compatibility adapters, Optional Diagnostics transport, managed deployment, and other release infrastructure follow only after the vertical slice is reliable in daily use. The architecture may expose small seams required by accepted contracts, but it does not build speculative frameworks for deferred features.

## Current implementation

This record describes the historical milestone order. The current beta already includes application updates, vocabulary package import, the full transcription-model option, configurable triggers, pinned microphones, and optional grammar correction. Diagnostics transport and managed deployment remain deferred.
