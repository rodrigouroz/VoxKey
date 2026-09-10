---
status: accepted
---

# Adopt Swift 6 strict concurrency

The VoxKey v2 rewrite uses Swift 6 language mode with complete strict-concurrency checking from the beginning. Actors and structured tasks own dictation-session state, model lifecycle, cancellation, Text Delivery, recovery, diagnostics, and UI handoff. Public cross-isolation values must be `Sendable`, and mutable session resources must have one explicit owner.

The real-time audio render callback is a deliberate Concurrency Boundary. It performs only bounded, real-time-safe transfer into a preallocated buffer and does not await actors, allocate unbounded work, log, touch UI state, or run inference. Structured consumers drain that buffer with explicit backpressure outside the render context.

VoxKey avoids `Task.detached`, orphaned continuations, fire-and-forget delivery, and scattered observable flags unless a narrowly documented platform boundary makes one unavoidable. Cancellation propagates from the session coordinator through capture, Provisional Decode, finalization, and delivery so a completed or cancelled session cannot mutate a successor.
