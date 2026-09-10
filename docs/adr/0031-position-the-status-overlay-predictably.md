---
status: accepted
---

# Position the status overlay predictably

The Status Overlay appears as a compact pill near the upper-right of the display containing the Destination. If VoxKey cannot resolve a Destination display, it uses the active display. It does not chase the caret, pointer, or changing focus while a dictation is in progress.

This fixed placement keeps capture state visible without depending on unreliable caret geometry from third-party Accessibility implementations, while avoiding the bottom-mounted text composers common in chat, browser, and Electron applications. The overlay remains nonactivating during capture, processing, and its brief content-free outcome state, and it must account for the visible screen frame, Dock, menu bar, full-screen spaces, and multiple-display changes.

## Current implementation

The upper-right placement and visible-screen-frame inset are implemented. The current display selection follows the pointer when the panel is positioned, falling back to the main screen. Destination-display selection and pinning through a session remain unimplemented.
