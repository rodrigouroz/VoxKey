---
status: accepted
---

# Run as a menu-bar utility

VoxKey runs as a menu-bar utility without a persistent Dock icon or application-switcher entry. The status item communicates readiness and provides access to Settings, the Safety Net when a Last Result exists, selected-model status, and Quit. A diagnostics viewer/export flow remains unimplemented.

While Settings and Readiness is open, including first-run onboarding and permission repair after a previously completed setup, VoxKey temporarily uses the regular foreground application posture and hides the status item only if that change succeeds. The Dock and application switcher keep setup reachable when a system permission alert takes focus. Opening VoxKey again brings this window forward. Closing it removes the Dock presence and restores the status item.

The Status Overlay remains nonactivating and never steals focus from a Destination. Settings, onboarding, and the deliberately opened Safety Net are normal keyboard- and VoiceOver-accessible windows with predictable focus behavior. Hiding the idle app must not make permissions, recording state, recovery, or quitting undiscoverable.
