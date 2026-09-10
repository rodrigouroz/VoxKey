# Architecture decisions and implementation status

ADRs preserve why a decision was made. `accepted` records an intended constraint;
it does not certify a shipped feature. Superseded records remain historical and
must not be used as current behavior. The [glossary](../../CONTEXT.md) describes
the current checkout; [Unreleased](../release/unreleased.md) separates pending
work from published release notes.

These gaps matter when describing the current release:

| Decision or requirement | Current implementation |
| --- | --- |
| [Verified model packages](0008-install-verified-model-packages-separately.md) | Grammar downloads verify pinned revisions, sizes, hashes, and conversion output. Transcription uses WhisperKit downloads and required-file checks; a shipped authenticated transcription manifest is still pending. |
| [Clipboard policy](0009-use-a-guarded-pasteboard-lease.md) | Guarded pasteboard delivery exists. Strict Clipboard Mode does not yet exist. |
| [Optional diagnostics](0016-make-outbound-diagnostics-opt-in-and-content-free.md) | No outbound diagnostics. Content-free entries use macOS unified logging; there is no app-owned log viewer, export, or retention policy. |
| [Direct distribution](0022-distribute-directly-with-signed-updates.md) | GitHub DMGs and signed Sparkle updates exist. Automatic checks are opt-in and installation needs confirmation. A managed installer is pending. |
| [Overlay placement](0031-position-the-status-overlay-predictably.md) | Upper-right placement is implemented. The display is selected from the pointer position when the overlay is positioned, not the captured destination. |
| [OS window](0006-use-a-rolling-two-version-macos-window.md) and [hardware floor](0038-set-the-hardware-floor-from-release-evidence.md) | The build floor is Apple Silicon/macOS 26. A rolling policy is not evidence of validation on every eligible OS, chip, or RAM configuration. |
| [Compatibility evidence](0028-require-compatibility-evidence-before-release.md) | Automated and controlled test-host checks exist. The [checklist](../release/core-compatibility-checklist.md) still needs candidate-specific third-party editor and physical-device records. |

Source checkpoints: [WhisperTranscriber](../../Sources/VoxKeyApp/WhisperTranscriber.swift),
[GrammarModelStore](../../Sources/VoxKeyApp/GrammarModelStore.swift),
[AccessibilityService](../../Sources/VoxKeyApp/AccessibilityService.swift),
[UpdateController](../../Sources/VoxKeyApp/UpdateController.swift), and
[StatusOverlayController](../../Sources/VoxKeyApp/StatusOverlayController.swift).
