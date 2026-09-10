---
status: accepted
---

# Rewrite v2 and port selectively

VoxKey v2 starts as a clean Swift 6 codebase designed around the accepted domain model, strict concurrency, Native Transcription Pipeline, safe Destination handling, and deliberately narrow Core Release. The abandoned VoxKey prototype and Yorick are reference sources, not architectural or Git-history foundations.

Implementation may port a component or focused algorithm only after verifying that it fits the new contracts and improves on rewriting it. Likely reference areas include Yorick's focus and secure-field research, guarded pasteboard behavior, recovery interactions, onboarding, signing, Sparkle setup, and lifecycle handling, plus any independently useful VoxKey tests or assets. Monolithic orchestration, subprocess transcription, persisted history, content logging, telemetry defaults, app-category injectors, and shared mutable audio state are not carried forward.

The current prototype does not require a compatibility layer, migration path, preservation tag, or continued buildability. Reused Yorick code or substantial portions retain their original MIT copyright and license notice. Conceptual inspiration alone does not require copying code, and new VoxKey code remains under the repository's MIT license.
