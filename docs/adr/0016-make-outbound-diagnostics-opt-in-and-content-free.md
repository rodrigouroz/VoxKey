---
status: accepted
---

# Make outbound diagnostics opt-in and content-free

VoxKey sends no analytics, diagnostics, or crash reports by default. Users may explicitly enable Optional Diagnostics, and company policy may prohibit them entirely. Permitted diagnostics include content-free state transitions, durations, redacted error codes, and model or runtime versions; they exclude audio, transcripts, surrounding text, pasteboard contents, application names, window titles, bundle identifiers, filenames, and accessibility-tree values. VoxKey keeps only a short-lived, inspectable Local Diagnostic Log that users export deliberately. This accepts weaker aggregate product analytics in exchange for a privacy boundary users and administrators can verify.

## Current implementation

There is no outbound diagnostics transport or settings control. Content-free operational entries use macOS unified logging; the application has no dedicated diagnostic viewer, export flow, or fixed retention period.
