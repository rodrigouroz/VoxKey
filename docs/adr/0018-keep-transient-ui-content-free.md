---
status: accepted
---

# Keep transient UI content-free

VoxKey's Status Overlay is non-activating and never takes keyboard focus; it and system notifications never display transcript content. During capture and processing they communicate state, level, time, and progress; ordinary success is quiet, while known failures and No Speech can produce brief content-free feedback. Transcript content appears only inside the recovery panel. A completed dictation without an editable destination opens that panel automatically as a neutral result; other recovery is opened deliberately. The Safety Net may show the Recovery Destination's application icon and display name, but not a window title, document name, URL, field label, or surrounding text. This preserves the Editing Intent, reduces disclosure during screen sharing, recording, shoulder surfing, and notification mirroring, and keeps microphone activity unmistakable.

Toggle Dictation keeps the waveform, trigger keycap, and “Listening — press <trigger> to finish” title visible throughout capture. The Dictation Limit warning remains visible at 70 seconds remaining. Trigger names are preference labels; no device name or application identity enters this surface.

During capture, a six-segment input meter communicates smoothed RMS level without a numeric readout. Level is calculated on ring-drained samples, with capture snapshots sampled no faster than 20 Hz; the render callback is unchanged. The meter is hidden outside capture and the pill remains 212–360 points wide. Initial silence below -60 dBFS receives a content-free microphone-check instruction; audible input without speech keeps the neutral No Speech message.
