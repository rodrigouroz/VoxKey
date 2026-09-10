# Delivery test host

VoxKey Test Host is a non-shipping macOS application containing controlled native, web-backed, secure, and non-editable destinations. It provides repeatable synthetic fixtures for the cross-process Accessibility and editor behavior that cannot run safely inside an ordinary Swift Package test process with VoxKey's macOS privacy grant.

The signed test-host builds require the maintainer certificate; see
[distribution](../release/distribution.md). Build and open both development applications:

```sh
./scripts/build-app.sh
./scripts/build-test-host.sh
open .build/VoxKey.app
open .build/VoxKeyTestHost.app
```

Use synthetic speech only. Unless explicitly launched with `--oracle-report <path>`, the test host does not persist fixture contents and is not copied into the VoxKey application bundle or release package.

## Automated boundary

`swift test --force-resolved-versions --no-parallel` verifies route selection, mutation confirmation, session transitions, dictation mechanics, and Pasteboard Lease preservation and ownership using uniquely named pasteboards. Automated tests never replace the user's general pasteboard and do not require Accessibility permission.

The signed test host covers the remaining system boundary: the real focused-element Accessibility tree, WebKit exposure, system keyboard paste dispatch, focus changes, and secure-field behavior. WebKit does not establish Electron compatibility; third-party surfaces need their own records. macOS grants Accessibility permission to a signed application identity; giving that permission to an ephemeral test runner would make the suite brittle and weaken the permission boundary being tested. See [delivery reliability](delivery-reliability.md) for the repeatable signed probe and known gaps.

The **Empty paragraph (normalize on input)** button creates a web paragraph containing only a placeholder BR. Its first input deliberately replaces that scaffold with the inserted text, reproducing a rich editor's disappearing-placeholder behavior through real WebKit Accessibility reads. Click inside the editor after resetting. Repeated resets are scoped to their own JavaScript invocation; **Reset (then click editor)** restores ordinary behavior. This is a controlled normalization fixture, not WebKit's default editing behavior.

## Core pass

For each editable fixture, reset and focus it before starting. WebKit does not reliably transfer native Accessibility focus from an AppKit button through programmatic DOM `focus()`, so after resetting the web fixture, click directly inside the editor and confirm that its caret is visible.

1. Dictate into the empty or reset field and confirm exactly one insertion.
2. Place the caret inside existing text and verify boundary spacing and capitalization.
3. Select `text` in the native field and verify exact replacement.
4. Verify the single-line fixture uses direct Accessibility delivery. The multiline fixture refuses the direct AX setter even though AppKit advertises it as writable. Production routes native multiline controls to keyboard paste before any AX mutation. The web fixture must resolve real focus before it can use a Pasteboard Lease; missing focus remains a failed acceptance case.
5. Put two synthetic items and a custom representation on a named test pasteboard through the automated suite; it must restore all of them after the lease.

## Safety pass

1. Focus the secure fixture and press the trigger. Capture must be rejected before the microphone opens.
2. Focus the non-editor target and dictate. The result must enter the Safety Net without blind delivery.
3. Schedule each three-second focus, caret, and nearby-text change, then immediately begin a dictation and keep speaking past the delay. VoxKey must not modify either destination and must preserve the result in the Safety Net.
4. Schedule the pasteboard change and test a paste-routed destination. VoxKey must never overwrite the newer clipboard value. If text was already verified in the destination, delivery may complete; otherwise the result remains quietly available in Last Dictation. Missing confirmation must not create failure attention.
5. Focus a fresh editable fixture, open Recover Dictation… from VoxKey’s menu, confirm its destination label, and press Return. Recovery must insert exactly once. Command-C must copy only after the explicit command.

Record the result using the core compatibility checklist. A failed required scenario blocks the corresponding compatibility claim.

## Independent oracle

Launch the host with `--oracle-report /tmp/voxkey-editor-oracle.json` to opt into a synthetic-only storage report. It reads native editor storage and observes DOM mutations, independently of Accessibility. Secure-field contents are excluded. The validation runner requires this report and compares all fixtures, so a successful AX read is never used to validate itself. Delete the temporary report after testing.
