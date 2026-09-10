# Delivery reliability

## Current delivery contract

When capture begins without a focused input or on a noneditable surface, successful transcription opens **Last Dictation** directly with “Your dictation is ready.” The panel displays the text and offers Copy or instructions for choosing an input and reopening the panel. This outcome has no warning toast or duplicate-insertion confirmation because no write was attempted. Permission, selection, destination-change, and other known blockers retain their warning behavior. A missing input never authorizes delivery into a field selected later during transcription.

The outcome is now explicit: **delivered**, **unconfirmed**, or **failed before a possibly applied write**. A timed-out observation cannot distinguish failed insertion from stale accessibility metadata, a submitted draft, or an editor that does not expose its contents. Only a known blocker or rejection requests Safety Net attention. Unconfirmed delivery ends quietly, with the transcript available from **Recover Dictation…**. Opening that retained result and inserting again requires an explicit duplicate check.

The transcript is saved in memory before dispatch. An accepted AX request (including an ambiguous messaging failure) never authorizes a second write. Only explicit unsupported/not-implemented rejection allows paste fallback. No placeholder-specific normalization exception remains. The UI receives a typed attention event; retained text and status-message wording cannot create a failure toast.

Paste observation has a 150 ms foreground budget. Clipboard settlement can continue within the original two-second budget without delaying the ready UI or publishing another outcome. A new paste waits for the preceding lease; shutdown settles it. Full verification or positive inserted-text evidence allows earlier restoration; a newer clipboard owner is preserved. These are observation budgets, not hard bounds on external macOS calls.

## Routes and formatting

Eligible native single-line controls can use direct Accessibility insertion.
Native multiline and web editors use keyboard paste from the outset. An accepted
write that appears to do nothing is still potentially applied; it must not cause
an automatic second write. Focus, selection, surrounding context, secure input,
permissions, and clipboard ownership remain part of the guarded transaction.

Whole-word replacement can inherit a lowercase selection’s casing inside a
sentence and remove a lone transcription period. Recognized names, acronyms,
mixed-case forms, dotted abbreviations, sentence starts, partial-word selections,
and multiword inputs retain safeguards. Unrecognized title-case names can inherit
the selection style; this formatting is not general grammar correction.

## Repeatable validation

The suite exercises the real delivery service, focus resolver, session coordinator,
NSTextView storage, and uniquely named pasteboards. External AX and keyboard
boundaries are controlled in tests. Coverage includes stale or missing metadata,
delayed writes, focus and selection changes, secure input, clipboard ownership,
shutdown, and retained-result identity.

```sh
swift test --force-resolved-versions --no-parallel
./scripts/build-test-host.sh
./scripts/build-delivery-validation.sh
open .build/VoxKeyTestHost.app --args --oracle-report /tmp/voxkey-editor-oracle.json
```

The two signed probe builds require the maintainer certificate described in
[distribution](../release/distribution.md). After clearing and focusing a synthetic
fixture, run:

```sh
open -g -n .build/VoxKeyValidation.app --args --verify-delivery 20 /tmp/voxkey-delivery-report.json /tmp/voxkey-editor-oracle.json web
```

The runner is restricted to the test-host bundle, requires an empty editor, and
never opens the microphone or model. Its independent oracle compares native
editor storage or web DOM text and verifies neighboring fixtures are unchanged.
Select `nativeField`, `nativeText`, or `web` as the last argument. `--wait-for-focus`
allows 30 seconds to focus a fixture. Reports contain synthetic fixture text and
operational results; delete them after the check. The runner is excluded from
release builds. See [test-host instructions](delivery-test-host.md).

## Compatibility limits

### Diagnosing a rejected destination

This workflow requires an internal build (`VOXKEY_INTERNAL_DIAGNOSTICS`). Public
builds do not include these logs or the inspection entrypoint. Build an internal
candidate with `zsh scripts/build-app.sh release candidate`, or an internal debug
validation bundle with `zsh scripts/build-delivery-validation.sh`.

Read the running internal application's logs, excluding the test helpers that use the same subsystem:

```sh
/usr/bin/log show --last 15m --style compact --info \
  --predicate 'subsystem == "com.rodrigouroz.VoxKey" AND process == "VoxKey"'
```

An `unsupportedInsertion` capture rejection now records the target PID, AX role,
editable/enabled flags, selection availability, and selected-text writability.
These diagnostics contain no dictation, editor text, window title, or URL. A later
`no_destination_token` means transcription succeeded without an accepted input;
no insertion was attempted. It does not establish why the expected editor was not
the captured target. Correlate the PID and timestamp before attributing it to an app.

Internal builds also accept `--inspect-destination <pid> <report.json>`. Launch the
signed internal bundle through Launch Services with `open -g -n <bundle> --args ...`
to use its Accessibility identity. This mode compares application, system, and
resolved focus and inspects a bounded tree of control metadata. It does not start
the normal controller, microphone, or model, read editor text, or insert anything.
`treeComplete: false` means the inspection reached its node, depth, or time limit;
absence from such a report is not proof that a control is missing.

The September 10 Conductor check retrieved historical rejection logs, then
confirmed two user-performed composer dictations after restarting with diagnostics.
An independent metadata inspection found an enabled `AXTextArea` with a readable
selection and writable text. No rejection with a definitely focused composer was
reproduced, so no focus-routing change or universal compatibility claim followed.

Controlled native and WebKit fixtures do not establish compatibility with Slack,
Codex, VS Code, Chrome, or another third-party editor. Record microphone-to-editor,
cold-launch, insertion, replacement, cancellation, and recovery results for each
candidate using the [compatibility checklist](../release/core-compatibility-checklist.md).
A process-targeted key chord cannot atomically pin a field against a user changing
focus between validation and event handling. A destination that cannot expose
confirmation remains unconfirmed; reinsertion always requires checking it first.
