# Distributing VoxKey

Build and sign locally. GitHub Releases hosts the DMG; GitHub Pages serves Sparkle's
signed update feed at <https://rodrigouroz.github.io/VoxKey/appcast.xml>.
Both source and the feed live on `main`. CI tests and packages previews without secrets.

## Local iteration and release notes

Maintainers use `./scripts/build-app.sh release candidate` for local testing.
Contributors without the pinned certificate can use
`VOXKEY_SIGNING_IDENTITY=- ./scripts/build-app.sh release preview` with a separate
app identity. Local development
cycles do not create releases, tags, version bumps, or update-feed changes.
Collect user-visible changes and testing limits in [Unreleased](unreleased.md).

From Beta 4, optional grammar correction is available in all app build kinds;
the user's correction preference still defaults off. Every app includes the
grammar preparation resources and model terms, while large model files are
downloaded only after opt-in. CI checks the packaged preview's actual grammar
availability, visible controls, off-by-default state, and bundled terms.

For local validation against a signed app and an existing model installation:

```sh
VOXKEY_GRAMMAR_APP="$PWD/.build/distribution/VoxKey.app" \
VOXKEY_GRAMMAR_TEST_ASSETS="/absolute/path/to/gector-roberta-fp16-adaac6fb-v1" \
swift test --force-resolved-versions --no-parallel --filter 'packagedGrammarControls|packagedAppResources'
```

All local app, candidate, validation, test-host and distribution builds use the
certificate pinned in `scripts/signing-identity.sh`:
`Developer ID Application: Rodrigo Uroz (6QMEN99W4B)`, SHA-1
`0E2CEF88A0CD90DD1E3F047D711339DD9FBD6CC2`. This is public certificate metadata;
the private key stays in Keychain. Builds fail if that identity is unavailable,
instead of switching to Apple Development or an ad-hoc signature. Each build
verifies the signed app against the pinned leaf certificate. Certificate renewal
requires an intentional pin update and a privacy-identity compatibility check.

Local packaging previews use the same certificate. CI and contributors without the certificate explicitly set
`VOXKEY_SIGNING_IDENTITY=-` for preview builds only. All previews have the separate
bundle ID `com.rodrigouroz.VoxKey.PackagingPreview` and name **VoxKey Packaging
Preview**, so macOS does not confuse them with a permissioned VoxKey installation.
An override may name the pinned certificate or its SHA-1; other identities are
rejected. Use the signed candidate when validating the official app’s existing privacy grants.

If Accessibility is enabled in System Settings but VoxKey still reports it off,
first check the running app path and its signature. An ad-hoc build sharing
VoxKey's bundle ID can fail the existing TCC requirement even while the switch is
on. Quit that copy and open the signed candidate; do not reset all privacy grants
or add private entitlements. Apple's [code-signing requirements note](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
explains the identity used for privacy-protected resources.

Official releases require maintainer approval of scope and timing. At that point,
move the selected notes into the versioned release-notes file and leave any pending
changes in Unreleased. Publish the versioned notes with the GitHub release using
`--notes-file`; the feed script embeds those same notes in Sparkle's update window.

## One-time setup

- Xcode 26 / Swift 6.2+, an Apple Developer Program account signed into Xcode, and
  a **Developer ID Application** certificate with its private key in Keychain.
- Authenticate the [GitHub CLI](https://cli.github.com/).
- Configure GitHub Pages to deploy from **main → /docs** in repository settings.
- Generate a Sparkle key using the pinned SDK's tool after `swift package resolve`:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account VoxKey
```

The public key is already in `VoxKey/Info.plist`. Keep the matching private key in
Keychain and maintain a secure backup; never commit or upload it. Do not generate
a replacement key for each release. A different maintainer needs the existing key
or a planned key rotation. Apple and Sparkle signing keys are separate.

## Build a release

Use [Semantic Versioning](https://semver.org/) tags without a prerelease suffix: `vMAJOR.MINOR.PATCH`. Increment
PATCH for compatible fixes, MINOR for new functionality, and MAJOR for incompatible
public-contract changes once the project reaches 1.0. Before 1.0, document breaking
changes clearly in the release notes. The example below prepares `v0.2.0`.

1. Increment `CFBundleVersion` for **every** release, including when the marketing
   version changes. Never reset it. For `v0.2.0`, use marketing version
   `0.2.0` and build `7`. Sparkle compares the build number.
2. Add `docs/release/0.2.0.md`, describing changes and actual testing limits.
3. Run tests, commit on main, push, and require CI to pass on that commit. Record
   manual destination checks in the [compatibility checklist](core-compatibility-checklist.md).
   Do not claim untested editors are supported.

```sh
swift test --force-resolved-versions --no-parallel
git tag -s v0.2.0 -m 'VoxKey 0.2.0'
export VOXKEY_TEAM_ID='TEAMID'
export VOXKEY_PRIVACY_DENYLIST='/path/to/private-release-denylist.txt'
./scripts/package-release.sh v0.2.0
```

Packaging requires a clean tagged commit matching Info.plist. It builds arm64 with
the committed lockfile, signs the app and Sparkle helpers with Hardened Runtime,
and uploads an archive through the account already signed into Xcode. No password
export is needed. Apple receives the app and bundled resources, not user data.
Only an accepted, stapled app that passes Gatekeeper can proceed to packaging.

Packaged builds omit debug information and the SwiftPM checkout resource fallback,
remap compiler source paths, and strip linker debug paths before signing. A privacy
gate scans the signed app and the mounted final DMG, including resources, symlink
targets, extended attributes, and release metadata. It rejects home directories,
private temporary directories, the active checkout path, machine names, and the
maintainer's forbidden identifiers. A generic runtime temporary-file template used
by the updater is not a developer build path.

For notarized releases, `VOXKEY_PRIVACY_DENYLIST` must name a nonempty private UTF-8
file containing one forbidden literal identifier per line. Keep employer names,
private domains, and other personal terms there, outside tracked source. The gate
never prints matched values. CI runs the portable path checks and gate regression
tests; the maintainer's additional terms are checked locally before publication.
Any new resource dependency or packaging change must pass the final-artifact scan.

The output is an APFS/LZFSE DMG containing the **Developer ID signed, notarized,
stapled app**, an Applications shortcut, and the license. With Xcode authentication,
the DMG is an unsigned container; the app carries Apple's signature and ticket.
Sparkle separately signs the entire DMG for update integrity. Do not describe the
container itself as Apple-notarized. Build metadata records the exact distinction.

Optionally set `VOXKEY_NOTARY_PROFILE` to a profile created with
`xcrun notarytool store-credentials VoxKey-notary`. This selects the notarytool
workflow, which also signs, notarizes, and staples the DMG itself.

Outputs are in `dist/<tag>/`: DMG, SHA256SUMS, and build-info.txt. Existing output
directories are not overwritten. Packaging waits up to ten minutes for Apple's
explicit processing state; rejection or other errors stop immediately. If export
is still pending, the archive remains in `.build/notarization/<tag>/VoxKey.xcarchive`.
Inspect Apple's result before retrying. Do not resubmit or publish a failed app.

```sh
xcodebuild -exportNotarizedApp \
  -archivePath .build/notarization/v0.2.0/VoxKey.xcarchive \
  -exportPath .build/notarization/v0.2.0/notarized
```

For a local preview, use `./scripts/package-release.sh v0.2.0 preview`.
These `LOCAL-PREVIEW` artifacts are never distribution releases and
do not join the public update feed. CI retains them for seven days.

## Publish the release, then the feed

Use the matching version in each command. Never move a published tag or replace
published binaries. Fix a release by increasing the build number.

```sh
git push origin v0.2.0
gh release create v0.2.0 \
  dist/v0.2.0/VoxKey-v0.2.0-arm64.dmg \
  dist/v0.2.0/SHA256SUMS dist/v0.2.0/build-info.txt \
  --verify-tag --draft --prerelease=false --title 'VoxKey 0.2.0' \
  --notes-file docs/release/0.2.0.md
```

Verify the draft's downloaded bytes/checksum, mount the DMG, and check the enclosed
app's signature, stapled ticket, and Gatekeeper assessment. Exercise installation
on another Mac/user account when available; clearly state what remains untested.
Do not bypass Gatekeeper to claim success.

```sh
gh release edit v0.2.0 --draft=false --prerelease=false --latest=true
./scripts/prepare-appcast.sh v0.2.0
git diff -- docs/appcast.xml
git add docs/appcast.xml
git commit -m 'Publish 0.2.0 update feed'
git push origin main
```

The feed script checks that the release is public, downloads and compares the DMG
to the local artifact, rejects decreasing/reused builds, and signs the feed with
Sparkle's official `generate_appcast`. It preserves older entries and embeds release
notes. Do not edit signed XML afterward. Wait for Pages deployment and verify the
live feed and enclosure URL. Publishing the asset first prevents broken update links.

## Test an update

Install the previous published version from its DMG, then publish the next release with
the same signing identities and feed URL. Use **Check for Updates…**, install,
and verify the new build after restart with vocabulary and model preparation
preserved. Check cancellation, dictation, and Safety Net recovery after updating.

Automatic checks are opt-in through Sparkle's prompt or the menu toggle and run
roughly hourly while the app is open. Installation requires confirmation. An update
waits for active dictation and unresolved recovery before restarting. Published releases use one feed; older beta entries remain available to existing
installations. Sparkle compares the internal build counter, so 0.2.0 build 7
updates correctly from 0.1.0 beta builds even though the tag format changed.

## References

- [Sparkle setup and signing](https://sparkle-project.org/documentation/)
- [Sparkle publishing and versioning](https://sparkle-project.org/documentation/publishing/)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
- [GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)

## Diagnostic boundary

Public packages must pass `python3 scripts/verify-no-diagnostics.py <app-bundle>`.
`build-app.sh` enforces this for `app`, `preview`, and `distribution`, independent
of optimization level. Only `candidate` enables `VOXKEY_INTERNAL_DIAGNOSTICS`.
Internal candidates and validation bundles must never be published as releases.
This gate removes VoxKey's diagnostic messages and inspection commands; it does
not assert that macOS or third-party frameworks cannot write system logs.
