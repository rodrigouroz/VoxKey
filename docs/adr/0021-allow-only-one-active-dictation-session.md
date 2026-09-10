---
status: accepted
---

# Allow only one active dictation session

VoxKey accepts a new trigger only while Always Ready. During Hold to Dictate capture and the subsequent Busy state, another trigger is rejected with brief feedback rather than cancelling, queueing, or overlapping work. This favors a small, generation-safe state machine over maximum capture throughput and prevents audio, decoder output, destination intent, and delivery completion from crossing session boundaries.

When Capture Sounds is enabled, rejection may be audible only after the microphone is closed and when it will not interrupt a start/end cue. While capture is open, feedback is visual so the rejection cannot enter dictation audio.

Toggle Dictation is opt-in. The state machine captures hold or toggle mode when reserving a session. In toggle mode, release is ignored (including arming), and a second activation during capture finalizes that same session. Arming, finalization, and delivery still reject presses. Escape, initial silence, permission revocation, device loss, and the ten-minute Dictation Limit still close capture safely. Preference changes affect subsequent sessions.
