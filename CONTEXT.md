# VoxKey

VoxKey is a free, open-source macOS dictation app. Speech recognition and optional grammar correction run entirely on the Mac. VoxKey records only during a deliberate dictation session.

## Current implementation and release scope

This glossary describes the current checkout. [Unreleased](docs/release/unreleased.md)
identifies changes beyond the latest published release. The current build requires
Apple Silicon and macOS 26+, uses Swift 6.2, and pins WhisperKit 1.1.0 and Sparkle
2.9.6. [README.md](README.md) covers installation and everyday use.

Accepted ADRs record decisions and intended constraints; acceptance does not mean
every requirement has shipped. Strict Clipboard Mode, outbound diagnostics,
managed deployment, a signed transcription-model manifest, and destination-based
overlay positioning remain unimplemented. See the [ADR implementation guide](docs/adr/README.md).
The Core Compatibility Matrix is an acceptance target, not completed certification
of every listed application or Mac.

## Language

**Safety Net**:
A user-visible panel for the volatile Last Result. The window is titled Last Dictation for a result without a known delivery failure and VoxKey Safety Net for a known failure. It supports validated recovery delivery, explicit copying, and dismissal. A completed dictation with no editable destination opens the panel automatically as a neutral result; other recovery is opened deliberately through Recover Dictation…. It is not a history and does not survive app termination.
_Avoid_: Silent fallback, clipboard fallback

**Recovery Destination**:
The editable text surface that has focus immediately before the user deliberately opens the Safety Net. VoxKey captures this target, displays only its application icon and display name, then revalidates it as an Editing Intent before recovery delivery. It never displays the destination's window title, document name, URL, field label, or surrounding text.
_Avoid_: New target, current app

**Destination Label**:
The application icon and localized application display name shown in the Safety Net so the user can confirm where Return will deliver the Last Result. It deliberately excludes bundle identifiers, window and document titles, URLs, field labels, and destination content.
_Avoid_: Window title, document identity, destination preview

**Recovery Delivery**:
The explicit Safety Net action, invoked by Return, that inserts the Last Result into a valid Recovery Destination using the ordinary Delivery Routes. It performs Text Delivery only and never sends, submits, or executes an action in the destination. Return is disabled when no safe Recovery Destination can be established.
_Avoid_: Retry paste, send recovered text

**Status Overlay**:
Transient, compact, non-activating UI near the upper-right of a display. It shows capture state, a smoothed six-segment RMS input level, the configured trigger, and Dictation Limit warnings; after capture it shows transcription or correction state. It hides during delivery and after ordinary success, with brief content-free feedback for No Speech or known failures. It never takes keyboard focus or displays transcript text. The current implementation selects the display containing the pointer whenever it positions the panel, falling back to the main display; destination-based positioning remains the ADR-0031 target.
_Avoid_: Transcript overlay, live caption, notification

**Menu Bar Utility**:
VoxKey's application posture while idle: a status item provides readiness, Settings, Safety Net access, model status, and Quit without a persistent Dock icon or application-switcher entry. While Settings and Readiness is open, including first-run onboarding and permission repair after a previously completed setup, VoxKey temporarily presents as an ordinary foreground application. It hides its status item only after creating the Dock presence, so a permission dialog taking focus cannot remove every route back. Opening VoxKey again brings this window forward; closing it restores the menu-bar posture. Deliberately opened Safety Net windows remain ordinary accessible windows even though the background utility does not become a conventional document application.
_Avoid_: Background daemon, Dock application, invisible process

**Capture Cues**:
Short, distinct audible confirmations that VoxKey is ready to capture and that capture has ended. They are enabled by default, may be disabled with Capture Sounds in the menu-bar menu, and accompany rather than replace the Status Overlay. The start cue completes before microphone capture opens and the stop cue plays only after capture closes, preventing VoxKey from recording its own feedback.
With sounds on, wait for the rising start sound before speaking; the falling stop sound confirms capture has closed, including Escape and initial-silence cancellation. With sounds off, capture has no sound-related arming wait; use the Listening overlay to begin speaking. Sound failure cannot block dictation. A quick release during the start sound stops it without opening the microphone.

_Avoid_: Voice prompt, notification sound, transcription chime

**Always Ready**:
The idle state in which the global trigger is active and the selected transcription model is prepared while the microphone remains off. Finishing onboarding attempts to enable Launch at Login; macOS may require approval, and Settings exposes its actual state and a disable control. VoxKey always provides Quit. Automatic unloading of the transcription model under memory pressure is not implemented.
_Avoid_: Always listening, continuous recording, always on

**Permission Ready**:
The state in which macOS has granted both Microphone and Accessibility access to VoxKey. These permissions are mandatory because capture and automatic Text Delivery are inseparable parts of the Core Release promise. Onboarding cannot complete without them, and VoxKey stops accepting new dictations if either permission is later revoked.
_Avoid_: Clipboard-only mode, degraded mode, permission warning

**Readiness Check**:
The successful end-to-end Live Dictation required to finish onboarding. A built-in editable field is treated as a real Destination through the production trigger, capture, transcription, Editing Intent, and Delivery Route pipeline. No test-only transcription or insertion path may mark VoxKey Always Ready.
_Avoid_: Microphone test, sample transcription, onboarding demo

**Busy**:
The state after capture ends but before its Final Result has completed Text Delivery or become the Last Result. A trigger pressed while Busy produces brief feedback (audible only with Capture Sounds enabled and the microphone closed); VoxKey never cancels the active result, queues another recording, or permits overlapping sessions.
_Avoid_: Processing queue, background dictation

**Destination**:
The editable text surface that has focus when a dictation begins and is therefore the intended recipient of its completed text.
_Avoid_: Active app, current cursor

**Secure Destination**:
A password field or another text surface that macOS marks as secure. If a Secure Destination has focus when the trigger is pressed, VoxKey refuses to start capture and provides a brief rejection indication. If a destination becomes secure during capture, VoxKey never reads from or delivers into it and sends completed text to the Safety Net. This prohibition has no override.
_Avoid_: Password field support, private input mode

**Unknown Destination**:
The state in which VoxKey cannot establish that the focused surface is editable but also has no evidence that it is secure. An Unknown Destination does not prevent capture; VoxKey makes the uncertainty visible and sends completed text to the Safety Net instead of attempting Text Delivery.
_Avoid_: Unsupported app, no focus

**Destination Change**:
The condition where the focused text surface at completion differs from the Destination. A Destination Change is treated as ambiguous and invokes the Safety Net rather than redirecting the text automatically.
_Avoid_: Focus handoff, automatic retargeting

**Editing Intent**:
The Destination, selection or caret range, and sufficient surrounding-text context captured when dictation begins. An unchanged selected range means replace it; an unchanged caret means insert at it.
_Avoid_: Focus snapshot, insertion point

**Editing Context**:
The volatile, bounded text VoxKey reads around an Editing Intent to validate conflicts and apply Dictation Mechanics. It contains at most 256 characters on each side of the caret or relevant selection boundaries, never expands to the whole field or document, is never supplied to the transcription model or diagnostics, and is discarded immediately after delivery, recovery routing, or cancellation.
_Avoid_: Document context, prompt context, field contents

**Editing Conflict**:
The condition where the Destination remains focused but its captured selection, caret, or relevant surrounding-text context no longer matches the Editing Intent. VoxKey invokes the Safety Net instead of overwriting or inserting into changed content.
_Avoid_: Stale selection, caret movement

**Text Delivery**:
The insertion or replacement of text in a Destination without sending, submitting, executing, or otherwise committing an external action.
_Avoid_: App interaction, output

**Faithful Transcript**:
Completed text that preserves the speaker's words and meaning without silently removing fillers, paraphrasing, summarizing, or changing tone. Default dictation produces a Faithful Transcript. An explicitly enabled Grammar Correction preference may adjust this transcript before delivery.
_Avoid_: Raw transcript, cleaned-up writing

**Final Result**:
The single completed transcript produced after capture ends, including Grammar Correction when explicitly enabled. VoxKey performs Text Delivery atomically using the Final Result and never inserts or displays provisional decoder text while the user is speaking.
_Avoid_: Live transcript, streaming text, partial result

**Provisional Decode**:
Local, in-memory transcription work performed incrementally during capture to reduce post-release latency and bound audio memory. Its text is never shown or delivered, is reconciled into one Final Result after release, and is discarded with Ephemeral Audio on cancellation.
_Avoid_: Live transcription, partial transcript

**Native Transcription Pipeline**:
The in-process Swift path from the Dictation Microphone through bounded volatile audio buffers into WhisperKit and Core ML. It uses no transcription subprocess, command-line model runner, temporary audio file, or intermediate encoded recording. Backpressure and structured ownership prevent unbounded queues and overlapping mutation.
_Avoid_: whisper process, temporary WAV, transcription service

**Concurrency Boundary**:
The ownership rule separating the real-time audio callback from Swift 6 concurrency. The callback performs bounded buffer transfer; actors own capture, model work, and session state, while the main actor owns UI. Task handles coordinate asynchronous work and cancellation. This is an ownership contract, not a claim that every task in the app is a structured child task.
_Avoid_: Actor everywhere, detached task, shared mutable buffer

**Dictation Mechanics**:
Deterministic, non-semantic adjustments that make a Faithful Transcript fit its Editing Intent, including unambiguous boundary spacing, capitalization, and duplicate-punctuation cleanup. Dictation Mechanics do not rewrite content.
_Avoid_: AI cleanup, transcript polishing

**Spoken Command**:
A phrase interpreted as an instruction rather than transcript content, such as "new paragraph" or "delete that." Spoken Commands are outside the core product scope because the Default Model transcribes phrases but does not reliably supply command semantics; VoxKey will not add its own command parser before the core dictation experience is proven.
_Avoid_: Voice shortcut, dictation grammar

**Polish**:
A potential future, explicit local-only action that semantically rewrites completed text. Polish is separate from ordinary dictation, visibly invoked, and never applied automatically.
_Avoid_: Smart dictation, automatic cleanup

**Grammar Correction**:
Optional, initially disabled local grammar correction of committed English transcription before Text Delivery. A bounded worker prepares the model and corrects confirmed phrases during recording; finalization reuses corrections only for identical model inputs, preserving final-text context. The choice appears during onboarding and in Settings. It adds processing and can change words; it is not a guarantee of grammatical accuracy or meaning preservation. Disabling cancels preparation, releases the loaded model and skips correction. Errors and unsupported inputs preserve the original transcript. The optional grammar feature downloads 519 MB from pinned original sources and prepares approximately 263 MB of GECToR Core ML FP16 assets locally, using only native code. The correction model uses Core ML CPU/GPU execution. Long text is split at sentence boundaries, or word boundaries for an oversized sentence, with at most 80 tokens and five edit iterations per model input. Unchanged separators are preserved. Whisper allows all Core ML processors; its uncorrected confirmed text remains the context for subsequent transcription. Beta 4 makes this feature available for explicit opt-in. Its noncommercial model terms remain separate from VoxKey's MIT source license; VoxKey downloads the large model files from their original sources rather than redistributing them.

**Delivery Route**:
The mechanism VoxKey uses for Text Delivery. Web-backed, custom, and native multiline editors normally use a Pasteboard Lease; eligible native single-line controls may use direct Accessibility insertion. Only an explicit unsupported/not-implemented rejection permits paste fallback; an accepted or ambiguously applied direct write never authorizes a second write. A known blocker or rejection requests Safety Net attention. A possibly applied write that cannot be confirmed preserves the result quietly and is never automatically retried. Blind Unicode keystroke injection is not a Delivery Route.
_Avoid_: Injector, typing strategy

**Destination Capabilities**:
The observed properties of a Destination that govern safe delivery, including application and window identity, accessibility role and subrole, secure state, selection support, and available insertion mechanisms. VoxKey selects a Delivery Route from these capabilities rather than from broad app categories.
_Avoid_: App type, injector class

**Compatibility Adapter**:
A narrowly scoped, tested exception for a specific application behavior that cannot be handled correctly through Destination Capabilities alone. An adapter is introduced only from reproduced evidence and is not a general routing category.
_Avoid_: Slack injector, browser injector, Electron injector

**Core Compatibility Matrix**:
The named destinations VoxKey must exercise before a Core Release: Notes and TextEdit for native macOS fields; Gmail, Google Docs, Notion, and Linear in Chrome; and Slack, Codex, and Cursor or VS Code for Electron surfaces. Other editable destinations remain best effort and must fail into the Safety Net rather than receive blind delivery. The matrix is a testing and product-claim boundary, not an app-based routing architecture.
_Avoid_: Works everywhere, supported app mode, universal compatibility

**Compatibility Evidence**:
A completed, reproducible acceptance record for a named destination on the Rolling OS Window. It covers ordinary insertion and replacement plus safety behavior when focus, content, permissions, or delivery routes change. A destination with a required failure is removed from the supported claim until fixed and retested.
_Avoid_: Seems to work, spot check, best-effort support

**Pasteboard Lease**:
A guarded, temporary use of the macOS pasteboard for Text Delivery. VoxKey snapshots every item and representation, marks transcript content as transient and concealed, pastes it, and restores the snapshot only if the user has not changed the pasteboard in the meantime. Transcript content is never intentionally left on the pasteboard.
_Avoid_: Clipboard fallback, copy and paste

**Strict Clipboard Mode**:
A planned privacy setting that would prohibit Pasteboard Leases and route paste-only destinations to the Safety Net. The current release has no Strict Clipboard Mode control or enforcement path.
_Avoid_: Disable clipboard history, secure paste

**Automatic Action**:
An optional future follow-up to Text Delivery that commits an external action, such as sending a message or submitting a form. It is excluded from the Core Release and is never part of ordinary dictation.
_Avoid_: Auto-send, implicit submission

**Core Release**:
The first production-quality release whose complete promise is: press, speak, release, and text appears safely or remains temporarily recoverable as the Last Result. It handles live microphone dictation only. Audio-file transcription, meeting recording, batch processing, Automatic Action, Polish, and Spoken Commands are excluded until this behavior is proven trustworthy.
_Avoid_: MVP, feature-complete release

**Clean Rewrite**:
The implementation strategy recorded in ADR-0040: build the current Swift 6 source under Sources/ around explicit session, transcription, and delivery contracts, using prior projects only as references or sources of compatible components. This describes the project's development history, not a pending migration or a second application version that users must install.
_Avoid_: Yorick fork, prototype migration, ground-up reinvention

**Live Dictation**:
A deliberate, bounded microphone capture started through a VoxKey trigger for immediate local transcription and Text Delivery. It is not a recording workflow and does not accept files, system audio, meetings, or background speech.
_Avoid_: Recording, audio transcription, meeting capture

**Delivered Dictation**:
A dictation whose completed text has been delivered successfully. Its audio and transcription are no longer retained by VoxKey.
_Avoid_: History item, completed capture

**Last Result**:
The single completed transcript retained in volatile memory when delivery is unavailable, unconfirmed, or known to have failed. It is stored before attempting an external write and cleared when delivery is confirmed. A newer result can replace it; quit, crash, or restart loses it. A result produced without an editable destination is presented neutrally for copying. An unconfirmed write stays quietly recoverable and requires an explicit checked-input confirmation before reinsertion. Cancellation or No Speech does not create a new result and need not clear an older one.
_Avoid_: Unresolved Dictation, history item, saved draft

**Ephemeral Audio**:
Audio that exists only in volatile memory while VoxKey records and transcribes a dictation. VoxKey never writes dictation audio to persistent storage; if transcription fails or the app terminates, the audio is discarded and cannot be recovered.
_Avoid_: Recording file, saved audio, retry audio

**System Input Device**:
The current default microphone selected in macOS. VoxKey uses it unless the user pins a Dictation Microphone in Settings. A missing pin falls back to the System Input Device for that session, with a content-free Settings note. Device names appear only in Settings. A device change affects the next dictation; loss of the active device ends the current capture safely.
_Avoid_: Automatic microphone switching

**Dictation Microphone**:
The input selected only for VoxKey in Settings, defaulting to the System Input Device. A pinned choice is persisted by stable device UID, resolved at each capture start, and never moves an active capture.
_Avoid_: Device ID preference, global input override

**Transcription Failure**:
A dictation attempt for which VoxKey cannot produce completed text. VoxKey may retain non-content diagnostic metadata, but it does not create a Last Result and cannot offer an audio-based retry because the Ephemeral Audio is discarded.
_Avoid_: Last Result, saved recording

**No Speech**:
A normal capture outcome in which conservative voice-activity and model-confidence checks find insufficient speech. If the entire initial three-second window stays below the -60 dBFS audio floor, the Status Overlay says “No audio detected — check the microphone in Settings”; audible input without speech says “No speech detected.” VoxKey discards the Ephemeral Audio and Provisional Decode, provides a brief neutral cue, and performs neither Text Delivery nor Last Result creation.
_Avoid_: Empty transcript, transcription failure, cancelled dictation

**Local Transcription Boundary**:
The permanent product boundary requiring all capture, speech recognition, and transcript processing to occur on the user's Mac. Dictation audio and transcript content never leave the device, and VoxKey has no remote transcription provider or cloud fallback path.
_Avoid_: Local-first, offline by default, optional cloud transcription

**Offline Operation**:
The availability guarantee that an installed VoxKey application and Model Package remain fully usable without an account, sign-in, activation, license server, periodic entitlement check, or network connection. Explicit model setup and application update checks may use the network; neither is required for dictation after setup. There is no outbound diagnostics feature.
_Avoid_: Offline mode, grace period, license lease

**Local Diagnostic Log**:
Content-free operational entries written through macOS unified logging, including state transitions, durations, build identity, error categories, and delivery evidence booleans. VoxKey does not log audio, transcripts, surrounding text, clipboard contents, or destination identities. Retention is controlled by macOS; VoxKey does not currently provide its own log viewer, export flow, or fixed retention period.
_Avoid_: Activity log, transcript log, usage history

**Optional Diagnostics**:
A future, explicitly opt-in mechanism for sending content-free diagnostics, subject to ADR-0016. No outbound diagnostics transport or user control is implemented. Application update checks are a separate network activity.
_Avoid_: Telemetry, anonymous analytics, automatic crash reporting

**Supported Mac**:
The current build requires Apple Silicon and macOS 26 or later. This build floor does not establish acceptable latency or memory use on every chip and RAM configuration. The Core Release hardware claim requires the evidence described in ADR-0038 and the compatibility checklist; the full 1.51 GB model recommends at least 16 GB of unified memory. Intel Macs cannot run the distributed arm64 app.
_Avoid_: Any Mac, Intel-compatible Mac

**Rolling OS Window**:
The intended Core Release support policy for the current public major macOS release and its immediate predecessor, subject to the macOS 26 minimum build floor. Beta OS releases do not advance it. Compatibility must be tested before adding a new OS release to the supported claim; this policy does not override Package.swift or Info.plist.
_Avoid_: Latest macOS only, fixed minimum forever

**Default Model**:
The 594 MB compressed Core ML variant of Distil-Whisper large-v3, an English-only local transcription model derived from Whisper large-v3. VoxKey selects it for ordinary use without requiring the user to understand model families or runtimes.
_Avoid_: Recommended model picker, automatic cloud fallback

**Model Override**:
An explicit setting that lets a user replace the Default Model with another supported local model. The Core Release offers the full 1.51 GB Distil-Whisper large-v3 conversion as its only alternative, keeping both choices on the same WhisperKit and Core ML inference path; it is labeled as recommending at least 16 GB of unified memory. Activation succeeds only after the new model warms successfully and never silently downgrades. Parakeet TDT v2 and any second runtime are post-Core candidates. Model identity, download size, language coverage, expected resource use, and compatibility must be disclosed before installation or activation.
_Avoid_: Automatic model switching, hidden fallback

**Personal Vocabulary**:
A bounded list of names, acronyms, and technical terms supplied locally as recognition hints to the selected model. It combines user-managed entries with explicitly installed Vocabulary Packages, is not a guaranteed substitution dictionary, and never learns implicitly from dictated content.
_Avoid_: Custom dictionary, learned vocabulary, correction memory

**Vocabulary Package**:
A separately versioned file of recognition hints that a user can import independently from the VoxKey binary. A private Vocabulary Package is manually imported by a user after receiving it through their organization's distribution channel; VoxKey does not fetch it, embed it in a public build, or manage publisher keys. Import validates the package format and shows its name, version, and term count before activation. It may be synthesized from approved company sources and includes stable product and technical terminology while excluding employee, customer, and school names, ticket identifiers, incident-specific terms, secrets, source prose, and provenance. User-managed Personal Vocabulary remains private and local.
_Avoid_: Hardcoded vocabulary, company model, vocabulary plugin

**Model Package**:
Model files installed separately from the application. The transcription models are downloaded through WhisperKit into ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml; VoxKey checks required files and warms the model before activation, but does not yet pin and verify a shipped transcription-model manifest. Optional grammar correction has a separate native installer with pinned revisions, byte counts, SHA-256 checks, and a verified conversion recipe. Model installation is explicit; prepared models are reused for local inference. ADR-0008 describes the stronger intended transcription package contract.
_Avoid_: Bundled model, live model service, automatic model update

**Direct Distribution**:
The current release channel is a GitHub Releases DMG containing a Developer ID-signed and notarized app, with signed Sparkle updates served through GitHub Pages. A managed-deployment installer is a future Core Release target. The Mac App Store is not an initial distribution target.
_Avoid_: Unsigned download, App Store release

**Public Source**:
The MIT-licensed, openly available VoxKey application source and generic Vocabulary Package format. Official releases remain identifiable through Developer ID signing. Internal Vocabulary Package contents, signing credentials, and other company material are not part of Public Source, and any reused third-party code must retain its required notices. Separately licensed models are not covered by VoxKey’s MIT license.
_Avoid_: Public internal vocabulary, source-available binary, unofficial build

**Application Update**:
A signed VoxKey binary update offered through Sparkle in distribution builds. Automatic checks are opt-in; installation requires confirmation and waits while dictation or unresolved recovery is in progress. Local candidates and packaging previews do not start the public updater. Application updates never silently replace or activate a transcription model or Vocabulary Package.
_Avoid_: Model update, vocabulary update, forced restart

**Hold to Dictate**:
The default trigger behavior in which capture begins when the configured trigger is pressed and ends when it is released. Globe/Fn is the default trigger, subject to an onboarding conflict check, and Settings offers Globe/Fn, Right Option, Right Command, and Right Control (modifier-only; Caps Lock is unsupported). A 150 ms chord-detection window precedes activation; joining a chord after activation cancels capture without delivery. The behavior makes the microphone's active interval a direct, deliberate physical action.
_Avoid_: Push to talk, voice-activated recording

**Trigger Conflict**:
A detected collision between VoxKey's configured trigger and a macOS or application action. Settings explains the Globe/Fn system binding and right-modifier chord behavior; VoxKey does not silently take over a system gesture.
_Avoid_: Shortcut warning, ignored system binding

**Toggle Dictation**:
An optional trigger behavior in which one activation begins capture and a second activation ends it. It is available for accessibility and long-form use through the Toggle Dictation checkbox in Settings, must remain visibly active while recording, and is not enabled by default. Mode is fixed when a session begins; releasing the trigger is ignored in toggle mode, including while arming. A second press during capture finishes that session; presses during arming or Busy remain rejected.
_Avoid_: Hands-free mode, always listening

**Dictation Limit**:
The fixed ten-minute maximum capture duration. At 530 seconds, VoxKey begins showing the remaining time, so the first warning is at 70 seconds remaining. At 600 seconds it stops capture and finalizes available audio instead of discarding the utterance or silently starting another session.
_Avoid_: Recording timeout, session rollover

**Cancel Dictation**:
An immediate Escape action that stops capture, discards Ephemeral Audio and any partial text, and performs no Text Delivery. Cancellation does not create a Last Result.
_Avoid_: Dismiss overlay, pause recording
