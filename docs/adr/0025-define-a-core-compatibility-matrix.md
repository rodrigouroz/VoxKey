---
status: accepted
---

# Define a core compatibility matrix

The Core Release makes explicit compatibility claims for a bounded set of representative, high-value destinations:

- Notes and TextEdit for native macOS text fields
- Gmail, Google Docs, Notion, and Linear in Chrome for browser-hosted editors
- Slack, Codex, and Cursor or VS Code for Electron-hosted editors

Other editable destinations are best effort. When VoxKey cannot establish safe Destination Capabilities or validate the Editing Intent, it invokes the Safety Net rather than attempting blind insertion.

This matrix governs testing and release claims; it does not replace the capability-based Delivery Route architecture with app categories. VoxKey uses the same capability negotiation for every destination. A Compatibility Adapter for one named application may be added only after a reproduced failure demonstrates that capabilities alone cannot handle it, and the adapter must carry focused regression coverage.

“Works everywhere” is not a Core Release claim. The matrix may expand only when a destination has repeatable acceptance evidence on the Rolling OS Window.
