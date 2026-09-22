# Local performance recording

Build with `./scripts/build-app.sh release performance`. This creates an optimized,
Developer ID signed `.build/VoxKeyPerformance.app`, preserving VoxKey's existing
preferences, models, and permission identity. Quit other VoxKey instances before
opening it. The menu says **Performance Recording On** and provides **Show
Performance Reports…**. Recording is enabled only in this explicit local build;
use the ordinary app to stop. The public updater is inactive in local builds.

Use it normally, including several 60–120 second continuous dictations and some
short requests. If convenient, include sessions with Improve transcription both
on and off. Keep the model/language consistent within comparisons. No need to
dictate artificial text or export transcripts. A physical microphone/editor
session is still required to qualify end-to-end behavior.

Records live in `~/Library/Application Support/com.rodrigouroz.VoxKey/Diagnostics/Performance`.
They contain only timings, numeric counters, model/language/build identifiers,
outcome, process CPU time, thermal state, and sampled resident memory. Destination
and delivery diagnostics add fixed rejection codes, allowlisted Accessibility
roles/error codes, capability booleans, bounded search statistics, insertion route,
and confirmation result. Application categories are limited to Conductor, Codex,
Cursor, Claude, and `other`; arbitrary application names are never stored. No audio,
transcripts, vocabulary, window titles, or destination content is saved.
Files are owner-only and excluded from backup. Saving prunes to the
latest 200 records and removes records older than seven days. Delete this folder
to discard the measurements.

Run `python3 scripts/performance-report.py` to summarize local observations.
Groups separate build, model, language, improvement setting, and captured-audio
duration. Failed/cancelled sessions are counted but excluded from completed
transcription latency summaries. No data is uploaded.

The destination/delivery fields are additive: old records remain readable and all
performance measurements remain enabled. A rebuild does not clear saved reports.
Each operation retains its last eight focus-resolution attempts plus the total
attempt count. Diagnostics reuse existing AX results rather than issuing extra
cross-application queries. A captured destination is not proof of delivery, and
an unconfirmed result is not proof that insertion failed.

Measurement boundaries:

- Stop time is when the coordinator handles release, toggle-stop, or the capture
  limit, not the hardware key event. Recognition readiness is measured inside
  the transcription task, independently of the stop cue. Completion includes
  delivery verification, or preservation in Safety Net when no destination exists.
- Preview/authoritative inference durations are wall time and can overlap other
  stages. Do not add them to derive end-to-end latency or call them GPU utilization.
  Preview audio seconds count repeated attempts, including interrupted ones.
- `finalTailAudioSeconds` is the uncommitted audio passed to final recognition;
  `maximumUncommittedAudioSeconds` also sees earlier phrase buffers.
- CPU is a process-wide delta, including unrelated work in VoxKey; the capture
  delta includes arming. Memory is sampled at lifecycle milestones, not a true
  peak. These are not power/energy measurements. Use Instruments for allocation,
  CPU-stack, GPU, and energy attribution after identifying a suspect stage.
- Small fixed accumulators remain in memory while recording. Files are written
  on a serial utility queue after completion, never from the microphone callback.
  Forced termination may lose the active record or a queued write.

`VOXKEY_PERFORMANCE` is a separate compile flag from text diagnostics. Combining
it with `VOXKEY_RELEASE` fails compilation. Public artifact validation rejects its
markers; the local performance packager permits only performance markers while
still rejecting transcription tracing and destination inspection entrypoints.
