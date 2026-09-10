# Contributing

VoxKey requires Apple Silicon, macOS 26+, and Xcode 26 with Swift 6.2 or newer.
Start with [CONTEXT.md](CONTEXT.md), the [ADRs](docs/adr), and the
[design system](docs/design-system.md). Open an issue before a large feature or
architectural change. Keep pull requests focused and explain observable behavior.

```sh
swift test --force-resolved-versions --no-parallel
VOXKEY_SIGNING_IDENTITY=- ./scripts/build-app.sh release preview
```

The preview is written to `.build/packaging-preview/VoxKey Packaging Preview.app`
and uses a separate bundle identifier and preferences. Quit other VoxKey
instances before launching it. Ad-hoc builds may need fresh privacy grants after
rebuilding. Official candidates and releases require the maintainer's pinned
Developer ID certificate; contributors do not need that private key.

Test first-party behavior through real implementations. Use test doubles only at
external boundaries, such as Accessibility, microphone hardware, or audio output.
Use synthetic fixtures; never commit or persist real microphone dictation, private
vocabulary packages, or company work product. Keep `.private/` and `.build/` ignored.

The default suite requires no microphone grant or model download. AppKit tests
share the main thread, so use `--no-parallel` to prevent unrelated UI fixtures
from consuming clipboard and capture timing windows. Hardware/model tests are opt-in: see [delivery validation](docs/testing/delivery-test-host.md),
[streaming tests](docs/testing/streaming-transcription.md), and the
[release compatibility checklist](docs/release/core-compatibility-checklist.md).
Passing CI does not establish compatibility with every third-party editor.

Commit `Package.resolved`. Dependency upgrades require review and relevant
transcription/delivery checks; do not regenerate the lockfile incidentally.
CI pins actions to commit SHAs and Dependabot proposes monthly updates. Signing
credentials stay in a local Keychain, never in a pull request or CI artifact.

See [distribution](docs/release/distribution.md) for DMG builds and beta releases.
