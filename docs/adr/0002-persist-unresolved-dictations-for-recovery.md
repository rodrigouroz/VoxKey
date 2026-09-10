---
status: superseded by ADR-0020
---

# Persist unresolved dictations for recovery

VoxKey persists an Unresolved Dictation locally so the Safety Net survives an app crash, quit, or Mac restart. This is a deliberate exception to delivered-content non-retention: preventing the loss of undelivered words outweighs temporary local persistence. Content is removed as soon as the user delivers, copies, or dismisses it, and otherwise expires after a 24-hour Recovery Window that company policy may shorten.
