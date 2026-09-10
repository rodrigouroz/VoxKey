---
status: accepted
---

# Prohibit dictation into secure destinations

VoxKey never captures for, reads from, or delivers text into a Secure Destination, and this prohibition has no override. When the trigger is pressed in a known secure field, capture does not start and VoxKey provides a brief rejection indication. If the destination becomes secure during capture, completed text is routed to the Safety Net. Preventing accidental exposure of passwords or other protected input outweighs convenience and avoids relying on a delivery mechanism to preserve the security semantics of the destination application.
