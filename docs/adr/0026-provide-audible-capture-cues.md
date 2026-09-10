---
status: accepted
---

# Provide audible capture cues

VoxKey provides short, distinct audible cues for the beginning and end of capture in addition to the Status Overlay. Cues are enabled by default and can be disabled with Capture Sounds in the menu-bar menu. They follow the user's output-volume setting and do not speak, expose transcript content, or replace visible microphone state.

The start cue completes before VoxKey opens microphone capture; the user begins speaking after hearing it. The stop cue plays only after microphone capture has closed. This ordering prevents the application's own sounds from entering Ephemeral Audio. Cue playback failure must not block dictation, and disabling cues must not alter capture timing beyond removing their brief arming interval.

## Implementation and preference rationale — 2026-09-08

Keep this preference enabled by default. Audible confirmation helps users who are looking at their destination rather than the overlay, but silent operation is useful in shared spaces, calls, and for people who find repeated sounds distracting. Neither mode changes transcription, destination safety, recovery, or the availability of visual feedback. Muted output may also make enabled sounds inaudible; the overlay remains authoritative.

The menu uses the plain-language label **Capture Sounds**, with help explaining silent operation. This is a utility preference in the existing menu; a separate Settings window is not required for this control.

The application owns three short PCM assets: a rising two-tone start cue, a falling two-tone stop cue, and a short rejection tone. These are original synthesized tones, generated at 44.1 kHz, mono, 16-bit PCM with tapered edges and a peak amplitude of 0.16. Start/stop last 120 ms; rejection lasts 60 ms. They contain no recorded or third-party content.

Playback uses AVAudioPlayer completion/error callbacks. A one-second watchdog forcibly stops a stalled output before releasing the wait; this is a failure bound, not normal capture timing. A rejected playback starts dictation without waiting. Disabling sounds or cancelling arming stops current output before releasing the start wait. Early trigger release does not open the microphone.

The session coordinator owns start/end sequencing directly. Normal release, Escape, initial-silence cancellation, the duration limit, and capture-stop failure provide an end cue after input closes. Cancelling arming produces no end cue because capture never opened. Termination closes capture without requiring a sound. Transcription may run during the end cue, but another capture is not accepted until that sound is finished or stopped. End feedback does not depend on delivery of UI snapshots.

Rejection never interrupts a start/end cue and never plays into an open microphone. During capture, rejected triggers use visual feedback. No extra audible success, transcript, or No Speech announcement is added; the capture-end sound already confirms the microphone closed.
