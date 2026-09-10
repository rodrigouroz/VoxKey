# VoxKey

**Hold a key. Speak. Keep writing.**

100% local dictation for your Mac. Free forever and fully open source. Hold your **Dictation trigger** (Globe/Fn by default), speak, and release to insert
English text where you started typing. Powered by WhisperKit, with speech
recognition running entirely on your Mac.

## Get started

Requires **Apple Silicon** and **macOS 26 or later**.

Packaged downloads and automatic updates are temporarily unavailable.
You can [build VoxKey from source](#development). Existing installations continue
to work.

1. Launch VoxKey and grant Microphone and Accessibility access.
2. Follow setup to download and prepare the English model.
3. Focus a text field, hold your configured trigger, and speak after the capture sound.
4. Release to finish. Press Escape to cancel.

VoxKey lives in the menu bar. Turn off **Capture Sounds** for silent use and speak
when the overlay says **Listening**. Add recognition hints in **Vocabulary…** or
import a vocabulary package and inspect it with **View Contents**.

Completed phrases are transcribed while you speak; only the final text is inserted.
If delivery cannot be confirmed, **Safety Net** keeps the result available for recovery.
**Recover Dictation…** appears in the menu only when a result needs recovery,
including when there was no destination. Confirmed delivery clears the result.

Choose **Globe/Fn**, **Right Option**, **Right Command**, or **Right Control** in
**Settings and Readiness… → Settings → Dictation trigger**. Use the key alone;
Caps Lock is unsupported. A brief chord-detection delay precedes activation;
joining a shortcut while holding the trigger cancels dictation. Left modifiers
keep their normal meaning. Settings changes apply on the next press.

Enable **Toggle Dictation** in Settings to press once to start and
again to finish. The overlay stays visibly active and names the finish trigger.
Escape cancels; initial silence stops capture after about three seconds, and
the ten-minute Dictation Limit still applies with a 70-second warning.

Choose a **Microphone** in Settings to pin an input just for VoxKey. The default
follows macOS. If a pinned input is disconnected, the next dictation uses the
system default and Settings explains the fallback. Changes never move an open
capture; losing its microphone ends that capture safely.

While **Listening**, six small bars show incoming microphone audio. No bars and
“No audio detected” mean you should check Microphone in Settings. The meter
hides as soon as capture ends and never displays words or a microphone name.

Enable **Correct grammar locally** in onboarding or **Settings and Readiness… → Settings**
to download the optional grammar model (519 MB). It defaults off. Dictation continues
during preparation; correction starts automatically when the model is ready and works
offline afterward. The model is for noncommercial use and may change words.

## Privacy

Audio and transcripts stay on your Mac. VoxKey does not save recordings or a
dictation history. Preferences, vocabulary, and downloaded models are stored locally.
Model setup and update checks require internet access; dictation uses the prepared
local model. Update checks contact GitHub and include app and Sparkle version information;
Sparkle system profiling is disabled.
Your destination app and clipboard control what happens to text after delivery or copy.

## Releases

GitHub Releases provide a **DMG**, release notes, and a checksum. The app is
Developer ID signed and notarized by Apple.

Choose **Check for Updates…** in the VoxKey menu to install a newer version through
Sparkle. Enable **Automatically Check for Updates** for background checks; VoxKey
asks before installing and restarting. Updates wait while dictation or Safety Net
recovery is in progress. You can also install any newer DMG manually.

VoxKey supports English dictation. Editor compatibility and real-world latency
are still being tested. See [0.2.0 release notes](docs/release/0.2.0.md) and
[how to build and publish a release](docs/release/distribution.md).

## Development

Requires Xcode 26 with Swift 6.2 or newer.

```sh
swift test --force-resolved-versions --no-parallel
VOXKEY_SIGNING_IDENTITY=- ./scripts/build-app.sh release preview
open ".build/packaging-preview/VoxKey Packaging Preview.app"
```

The preview has its own app identity and preferences and does not require the
maintainer’s signing certificate. Quit other VoxKey instances before launching it.
See [Contributing](CONTRIBUTING.md) for setup, testing, and project documentation.

## Feedback

[Report a bug](https://github.com/rodrigouroz/VoxKey/issues) with your Mac chip,
macOS version, VoxKey build, and destination app. Use made-up text in examples;
never attach real dictation or private vocabulary. Report vulnerabilities through
[Security](SECURITY.md).

[MIT license](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)

The MIT license covers VoxKey's source, not separately licensed model assets.
Optional local grammar correction uses a separately downloaded, noncommercial-only model;
see [model terms and testing results](docs/research/grammar-candidate.md).
