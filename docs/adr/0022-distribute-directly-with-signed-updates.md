---
status: accepted
---

# Distribute directly with signed updates

VoxKey's Core Release is distributed as a Developer ID-signed and notarized application with signed Sparkle updates, plus an administrator-friendly package for managed deployment. The Mac App Store is not an initial target. This preserves control over the global-trigger, Accessibility, model-package, and update experience. Yorick's distribution setup is a reference and possible source of focused reusable code, not the v2 application foundation.

VoxKey checks for and downloads signed application updates automatically. It never interrupts capture, processing, Text Delivery, or an open Safety Net, and installs a staged update only on a later relaunch. A failed update leaves the current application usable.

This automatic path applies only to the application binary. Model Packages and Vocabulary Packages can materially change recognition behavior and therefore remain separately versioned, visible, and explicitly installed or activated by the user.

## Current implementation

Distribution builds use signed Sparkle updates. Automatic checks are opt-in and installation requires confirmation, deferred while dictation or unresolved recovery is active. Candidates and previews do not start the updater. GitHub Releases distributes DMGs; a managed-deployment package remains planned.
