---
status: superseded by ADR-0042
---

# Follow the system input device

The Core Release always uses the current default macOS input device. VoxKey resolves the device when a dictation begins, displays its name only in Settings, and does not provide or persist a separate microphone selector.

Changes to the system default apply to the next dictation rather than moving an active capture between devices. If the active input device disappears during capture, VoxKey closes the session safely and attempts to produce a Final Result from audio already captured. If that audio cannot produce speech, the ordinary No Speech or Transcription Failure behavior applies. VoxKey never persists audio for a later retry.
