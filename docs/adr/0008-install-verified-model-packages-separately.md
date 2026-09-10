---
status: accepted
---

# Install verified model packages separately

VoxKey installs its Default Model as a separately versioned Model Package during onboarding rather than embedding it in every application build. Downloads must be authenticated and checksum-verified against a manifest shipped through a trusted update path; administrators may preinstall or cache the same artifact. This keeps application updates small and permits fully offline operation after setup without weakening the Local Transcription Boundary. Model packages are never downloaded, replaced, or activated without an explicit user or administrator action.

Optional grammar correction follows the same separate-installation principle. An
explicit opt-in downloads 519 MB from pinned original sources, verifies their
SHA-256 hashes, and prepares approximately 263 MB of FP16 Core ML assets using
native Swift and Core ML. The final weight blob must match the qualified hash
before the installation is atomically activated. The app carries only a small
conversion recipe/model definition and licensing notices. Completed downloads
survive interrupted preparation; after success, the FP32 source is removed.
Disabling cancels preparation and unloads the model. A saved preference permits
offline reuse, but missing assets require another explicit download action.

## Current implementation

The grammar installer implements pinned revisions, sizes, hashes, and exact conversion-output verification. The transcription installer still delegates downloading to WhisperKit, checks required files, and warms the model. It does not yet implement the authenticated manifest required above.
