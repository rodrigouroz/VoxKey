---
status: accepted
---

# Allow a pinned Dictation Microphone

Supersedes ADR-0027. The default remains System Input Device. Settings may pin an input for VoxKey only, persisted by stable CoreAudio UID rather than transient AudioDeviceID. Resolve the pin at each capture start. If it is absent, use the system default for that session and explain the fallback in a content-free Settings note; absence is not a dictation failure.

Enumerate devices with input streams and observe device-list and system-default changes to refresh Settings. Device names appear only in Settings, never in the Status Overlay, notifications, or Local Diagnostic Log (ADR-0016 and ADR-0018).

Explicitly bind the audio engine to the resolved device before reading its input format, including when following the system default. Preference and system-default changes never migrate an active capture. If the active device disappears or its engine stops, close capture and attempt a Final Result from already captured Ephemeral Audio; ordinary No Speech or Transcription Failure outcomes still apply. Audio is never saved for retry.

The AudioInputDevice protocol remains the hardware test boundary. Default tests exercise identifier selection, fallback and loss with synthetic input. Permission-dependent hardware and reconnect validation belongs in the Core Compatibility Checklist.
