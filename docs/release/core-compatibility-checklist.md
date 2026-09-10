# Core Compatibility Checklist

Complete one record for each destination claimed as supported. Use synthetic text only.

Run the controlled native and web boundary pass in [the delivery test host](../testing/delivery-test-host.md) before recording third-party destinations.

## Environment

- Tester:
- Date:
- Mac model:
- macOS version:
- VoxKey version:
- Model package and version:
- Vocabulary package and version, if active:
- Destination application and version:
- Destination surface:
- Focus Resolution path (`ordinary`, `manual_accessibility`, `enhanced_user_interface`, `system_wide`, `observed_event`, or `focused_window`):
- Observed Delivery Route:

## Required destination scenarios

- [ ] Insert into an empty editable field.
- [ ] Insert at a caret inside existing text with correct boundary spacing and capitalization.
- [ ] Replace an unchanged selection without affecting surrounding text.
- [ ] Deliver a multiline Final Result atomically.
- [ ] Move focus before completion; VoxKey preserves the result in the Safety Net and does not redirect it.
- [ ] Change the original selection or nearby content before completion; VoxKey detects the Editing Conflict.
- [ ] From the Safety Net, Return delivers to a newly captured and revalidated Recovery Destination.
- [ ] Command-C in the Safety Net copies the Last Result only after the explicit command.
- [ ] If the destination requires a Pasteboard Lease, the original pasteboard is restored unless the user changes it during delivery.
- [ ] After a fresh destination-app launch, the first dictation resolves the focused editor without requiring another assistive tool to inspect it first.

## Global safety scenarios

Run these once per supported macOS version and whenever the relevant implementation changes.

- [ ] Each configured trigger starts alone and releases once; left modifiers and Caps Lock never activate.
- [ ] Chords before/during the 150 ms detection window never open capture; a late chord cancels without delivery.
- [ ] Changing the trigger during a hold preserves its release; the next press uses the new choice without restarting the tap.
- [ ] Trigger preferences survive relaunch and all readiness hints match the selected trigger.
- [ ] Toggle Dictation is off by default, persists, and stays synchronized between Settings and the menu.
- [ ] Toggle capture survives release, ends on a second press, and keeps its finish instruction visible.
- [ ] Toggle capture closes on Escape, initial silence, the ten-minute limit (warning at 70 seconds remaining), device loss, and permission revocation.
- [ ] Changing capture mode or trigger during a session changes only the next session; arming/finalizing/delivering reject presses.
- [ ] Microphone Settings refreshes on connect/disconnect and system-default changes, including the current default name.
- [ ] Pinning a microphone survives relaunch by UID; reconnecting with a new transient ID resolves the same pin.
- [ ] An absent pin at capture start falls back to system default with a content-free Settings note, including disconnect during opening.
- [ ] Changing the default or pin never moves an active capture; losing its device closes input and finalizes available audio.
- [ ] Device names appear only in Settings, never in overlays, notifications, or logs.
- [ ] Listening shows a responsive six-segment input meter in hold and toggle modes, hidden as soon as capture ends.
- [ ] Silent input for the full initial three seconds says “No audio detected — check the microphone in Settings”; audible input without speech says “No speech detected.”
- [ ] Long finish instructions and the limit warning remain inside the 212–360 pt overlay, in light and dark appearance.
- [ ] A Secure Destination rejects capture before the microphone opens.
- [ ] Escape cancels capture without delivery or a Last Result.
- [ ] A trigger while Busy is rejected without queuing or interrupting work.
- [ ] Revoking Microphone or Accessibility permission blocks new dictations.
- [ ] A missing input device ends capture safely without persisting audio.
- [ ] When Strict Clipboard Mode is implemented, verify paste-only destinations enter Safety Net. Currently not applicable; the beta has no such setting.
- [ ] Native destinations stay on ordinary Focus Resolution; assistive-tree enablement occurs only after a focused-element lookup fails.
- [ ] Opening Settings and Readiness creates a temporary Dock presence before hiding the status item; closing restores menu-bar posture. Deliberate Safety Net access brings its window forward.
- [ ] Closing an active VoxKey window cooperatively restores the application that was active before it opened, but does not steal focus if the user already switched elsewhere.

## Result

- [ ] Pass: every required applicable scenario passed.
- [ ] Fail: remove the destination from the supported claim or link the reproduced defect and retest after correction.

Notes:

## Daily-app acceptance for the current delivery contract

Repeat in Slack message composer, Codex draft, VS Code editor, and a Chrome editable field:

- [ ] Empty input: dictate, confirm exact text once, then submit normally if desired. No delayed warning.
- [ ] Existing input: append and insert in the middle; preserve surrounding text.
- [ ] Selection: replace a word and a longer span; confirm exactly one replacement.
- [ ] Dictate twice quickly; each transcript appears once, clipboard remains intact.
- [ ] Switch destination while speaking: no redirected insertion; known failure offers Safety Net.
- [ ] Hold the trigger silently: capture stops after about three seconds; next dictation works.
- [ ] Recover Dictation… remains available quietly after an unconfirmed write; explicit reinsertion requires checking the destination first.

Record candidate `VoxKeyBuildID`, app version, actual editor result, and whether attention appeared. Synthetic fixtures do not establish these application compatibility claims.

## Capture Sounds

Run with the built app on speakers and a headset, at normal output volume and muted. Use synthetic dictation content only.

- [ ] On a fresh preference domain, Capture Sounds is checked; changing it survives relaunch.
- [ ] With sounds on, the rising start sound finishes before Listening/microphone capture; the falling stop sound starts only after input closes.
- [ ] Quick release or Escape during the start sound stops playback without opening the microphone.
- [ ] Release, Escape while capturing, initial-silence timeout, and the duration limit close input and produce one end cue. The next dictation works.
- [ ] Busy-trigger feedback does not interrupt an existing cue or enter an open microphone.
- [ ] With sounds off, all cues are silent; Listening remains visible, capture has no sound-related startup wait, and delivery/recovery behave normally.
- [ ] Muting or changing the output volume is respected. A missing/disconnected output cannot leave the session stuck arming or stopping.
- [ ] Start/stop sounds remain distinct and comfortable on both output routes; speaking after the start cue does not clip the first word.
- [ ] During local acoustic validation, cue audio is absent from captured samples; do not persist dictation audio or use transcripts as the sole proof of no leakage.

Hardware completion smoke test (plays the three short tones through the current output):

```sh
VOXKEY_VALIDATE_CUE_AUDIO=1 swift test --filter hardwareCaptureCueCompletion
```

## Recording acceptance

Record the current build ID and actual outcome for each applicable scenario.
Earlier candidate test counts and local render checks do not carry forward as
acceptance for a new build. Physical trigger behavior, microphone response,
device loss, permission revocation, and third-party editors require fresh checks.

A listen-only event tap cannot predict a future chord. Keys joining within the
150 ms detection window prevent activation; a chord joining an already active
hold cancels without delivery. A toggle finish already in finalization cannot be
undone by a later key.
