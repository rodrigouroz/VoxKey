---
status: accepted
---

# Restrict diagnostics to internal builds

Public VoxKey builds must not collect or store application diagnostics, telemetry, analytics, or application-managed crash reports. There is no end-user diagnostic opt-in. This supersedes the earlier proposal for an optional local log and outbound diagnostics.

Only explicitly flagged local Debug builds may contain diagnostic code. Release
candidates are diagnostic-free. Content-free logs may describe timing, state,
error categories, and control capabilities. Local Debug builds may additionally
record dictated text and model outputs only after a separate, default-off opt-in;
no audio is stored. The developer-only inspector is likewise excluded from releases.

## Current implementation

All diagnostic code uses `DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE`.
An explicit diagnostics flag with Release configuration or `VOXKEY_RELEASE` is a
compile error. `build-app.sh` allows the flag only for `debug development`; every
other bundle defines `VOXKEY_RELEASE`. Both the built bundle and the mounted final
DMG pass `verify-no-diagnostics.py`, which checks emitted messages, trace types,
recording controls, and inspection entrypoints. Saved preferences cannot restore
code excluded at compilation.

There is no outbound diagnostics transport or analytics/crash-reporting SDK. WhisperKit is configured with `verbose: false` and `logLevel: .none`; Sparkle's system profiling is disabled in both Info.plist and the updater startup code.

This is not a guarantee that macOS or dependencies produce no system logs. The pinned WhisperKit dependency includes signposts and Hub metadata warnings outside its configurable logger; Sparkle and Apple frameworks can also produce system diagnostics. Those are not removed by the first-party compile flag. An absolute zero-process-logs claim remains unsupported.
