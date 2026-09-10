---
status: accepted
---

# Use a guarded pasteboard lease as a first-class delivery route

VoxKey selects a guarded Pasteboard Lease immediately for web-backed and custom editors, where macOS Accessibility exposes selection state but does not provide a documented selected-text insertion operation. Eligible native single-line controls may use direct Accessibility insertion. Only an explicit unsupported/not-implemented rejection marks that route unsupported for the destination process; an accepted or ambiguously applied write never permits an automatic retry. Before starting a lease, VoxKey must snapshot every pasteboard item and representation or fail closed. It marks temporary transcript data as transient and concealed, and restores the complete snapshot only when the user has not changed the pasteboard meanwhile. VoxKey never uses blind Unicode keystroke injection; known blockers request Safety Net attention, while possibly applied but unconfirmed writes remain quietly recoverable. This accepts that an aggressive clipboard manager may observe temporary content in exchange for reliable editor-native delivery, with a planned Strict Clipboard Mode for users who need to prohibit pasteboard use entirely.

## Current implementation

The guarded lease is implemented. Strict Clipboard Mode is not exposed or enforced in the current beta.
