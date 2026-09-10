---
status: accepted
---

# Restrict diagnostics to internal builds

Public VoxKey builds must not collect or store application diagnostics, telemetry, analytics, or application-managed crash reports. There is no end-user diagnostic opt-in. This supersedes the earlier proposal for an optional local log and outbound diagnostics.

Only explicitly internal builds may include content-free diagnostics. These can describe timing, state, error categories, and control capabilities, but must not contain audio, dictation, surrounding text, clipboard contents, window titles, or URLs. The developer-only inspector can record the target application's identity and control metadata during an authorized investigation.

## Current implementation

All first-party log imports, loggers, messages, diagnostic-only reads, and inspection entrypoints are compiled behind `VOXKEY_INTERNAL_DIAGNOSTICS`. Ordinary builds default to diagnostics absent, including unflagged debug builds. The packaging script supplies this flag only for `candidate`; the development validation script also opts in. Public `app`, `preview`, and `distribution` bundles must pass `verify-no-diagnostics.py`, which checks the emitted executable for diagnostic messages and entrypoints rather than trusting the requested build mode.

There is no outbound diagnostics transport or analytics/crash-reporting SDK. WhisperKit is configured with `verbose: false` and `logLevel: .none`; Sparkle's system profiling is disabled in both Info.plist and the updater startup code.

This is not a guarantee that macOS or dependencies produce no system logs. The pinned WhisperKit dependency includes signposts and Hub metadata warnings outside its configurable logger; Sparkle and Apple frameworks can also produce system diagnostics. Those are not removed by the first-party compile flag. An absolute zero-process-logs claim remains unsupported.
