---
status: accepted
---

# Validate editing intent before delivery

VoxKey captures an Editing Intent when dictation begins and performs Text Delivery only if the destination, selection or caret, and relevant surrounding-text context still match at completion. An unchanged selection is replaced and an unchanged caret receives inserted text; a Destination Change or Editing Conflict invokes the Safety Net. This supports deliberate select-and-redictate workflows while preventing delayed transcription from overwriting or entering text after the user or application has changed the editing context.
