---
status: accepted
---

# Require microphone and accessibility permissions

The Core Release requires both macOS Microphone and Accessibility permissions. Onboarding remains incomplete until the user grants both permissions and VoxKey verifies their current state. VoxKey does not offer a capture-only, clipboard-only, or other degraded operating mode because automatic Text Delivery is part of the product's core promise rather than an optional convenience.

If either permission is denied or later revoked, VoxKey stops accepting new dictations, keeps the microphone off, shows a content-free explanation, and provides a direct route to the relevant System Settings pane. If Accessibility access disappears while a dictation is already being processed, VoxKey preserves any completed Final Result only as the volatile Last Result and exposes it through the Safety Net; it never attempts blind delivery.

VoxKey requests no additional privacy-sensitive permission without a demonstrated Core Release need. In particular, Input Monitoring must not be requested merely because the abandoned prototype requested it; the chosen global-trigger implementation must be tested against the supported macOS window first.

The configurable Globe/Fn and right-modifier triggers use the existing listen-only CGEvent tap. Trigger customization adds no permission or shortcut recorder. Chords detected within 150 ms do not activate; a later chord cancels the owned capture without delivery.
