---
status: accepted
---

# Load company vocabulary as separate packages

VoxKey loads separately versioned Vocabulary Packages rather than hardcoding company terminology into the binary or model. An organization-specific package is internal-only, may be synthesized from approved company connectors and source repositories, is distributed independently, and combines locally with user-managed Personal Vocabulary. It contains stable product names, acronyms, and technical recognition hints while excluding employee, customer, and school names, ticket identifiers, incident-specific terms, secrets, copied source prose, and provenance.

Terms carry prompt-selection priority rather than model-specific recognition weight. VoxKey puts user-managed Personal Vocabulary first, then adds package terms in descending priority until the selected model's context budget is full. A term is a hint, not a deterministic substitution rule. The package and the assembled model prompt remain inside the Local Transcription Boundary. Updating a Vocabulary Package never changes the application or transcription model silently.

For the Core Release, an employee receives the package through the organization's private distribution channel and imports it manually. VoxKey validates the package format, shows its name, version, and term count, and requires explicit activation. It does not authenticate to an organization, manage publisher keys or trust stores, embed the package in a public binary, fetch it from a public update feed, or silently provision it through managed deployment. User-managed Personal Vocabulary remains available for local custom terms.
