---
status: accepted
---

# Require compatibility evidence before release

A destination counts as supported only after it passes the repeatable Core Compatibility Checklist. Before release, the primary tester runs the checklist in the named applications that company members use and records the macOS, application, VoxKey, model, and Vocabulary Package versions involved.

VoxKey's state machine, Editing Intent validation, Delivery Routes, pasteboard behavior, and Safety Net receive automated coverage against a controlled local test host. Manual testing remains necessary for real third-party editors and Accessibility implementations. A required manual failure blocks the release claim for that destination: VoxKey either fixes and retests the behavior or removes the destination from the supported matrix.

Compatibility evidence contains only synthetic test text and operational outcomes. It does not retain real dictations, destination content, or company work product.
