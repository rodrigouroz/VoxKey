---
status: accepted
---

# Open source the application but not internal vocabulary

VoxKey publishes its application source and generic Vocabulary Package format. Company-internal Vocabulary Packages remain outside the public repository and public release artifacts; only their non-sensitive format and import behavior are public.

Public source makes the Local Transcription Boundary and diagnostic behavior independently inspectable. Official builds remain distinguishable through Developer ID signing and notarization. Forked Yorick code retains the copyright, MIT license notice, and attribution required by its upstream license, regardless of the license selected for new VoxKey code.

New VoxKey code is licensed under the MIT License. This deliberately permits use, modification, redistribution, sublicensing, sale, and closed-source commercial forks as long as the copyright and license notice are preserved. The license does not grant rights to VoxKey branding, official signing credentials, separately licensed models or dependencies, or internal Vocabulary Packages.

Secrets, signing credentials, private update infrastructure, internal download locations, and internal vocabulary contents must never enter the public repository or distributable application binary.
