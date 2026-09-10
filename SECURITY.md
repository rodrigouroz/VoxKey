# Security

VoxKey is pre-1.0 software. Security fixes target the latest release; older builds
do not receive a separate maintenance stream.

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/rodrigouroz/VoxKey/security/advisories/new).
Do not open a public issue containing exploit details, real dictation, private
vocabulary, destination content, or credentials. Include the version/build,
reproduction steps using synthetic text, and the expected privacy boundary.

Audio and transcription run locally. Accessibility and clipboard delivery are
sensitive capabilities: changes must preserve secure-field rejection, focus and
editing-intent checks, cancellation, and clipboard ownership. Transcription-model downloads use WhisperKit and are not yet pinned by a shipped,
authenticated manifest. Optional grammar-model downloads separately verify pinned
revisions, sizes, SHA-256 hashes, and the native conversion recipe. Neither model
is covered by the application signature alone. See the
[model integrity guide](docs/research/grammar-candidate.md#download-and-conversion-integrity).
