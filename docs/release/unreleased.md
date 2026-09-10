# Unreleased

## Dependency and UI candidate

- Upgrade WhisperKit from 0.15.0 to 1.1.0 using its canonical Argmax OSS repository.
  Keep the existing Distil-Whisper models and local inference path.
- Use the upstream prompt-prefill fix instead of VoxKey's vocabulary decoder adapter.
- Update packaging for the smaller dependency graph and bundle Argmax's vendored
  third-party notices. Refresh the compatible argument-parser pin.
- Share the forest-green palette and typography across Settings, Vocabulary,
  Safety Net, and the recording overlay. Match the public page to those colors
  and improve the readability of its demo captions on smaller screens.

The dependency candidate passed maintainer dictation testing. The combined UI
candidate is for renewed local validation before 0.2.1. Packaged downloads and
the public update feed remain paused. Validation results belong in the PR;
physical microphone and editor acceptance remain a separate step.
