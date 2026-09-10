---
status: accepted
---

# Bound and discard editing context

VoxKey may read up to 256 characters on each side of the caret or relevant selection boundaries to validate the Editing Intent and apply deterministic spacing, capitalization, and punctuation mechanics. Implementations must align reads to safe text boundaries and request the smallest Accessibility ranges that satisfy the operation; they must not fetch an entire field or document merely because the API exposes it.

Editing Context exists only in volatile memory for the active dictation. It is never written to disk, placed on the pasteboard, shown in the Status Overlay, included in Local Diagnostic Logs or Optional Diagnostics, or supplied to the transcription model as recognition context. VoxKey discards it immediately after Text Delivery, Safety Net routing, cancellation, or failure.

When a destination cannot expose a bounded range safely, VoxKey uses the context it can establish without broadening the read. If that evidence is insufficient to validate a replacement or detect an Editing Conflict, the completed Final Result goes to the Safety Net rather than triggering a whole-document read or blind delivery.
