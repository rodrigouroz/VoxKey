---
status: accepted
---

# Deliver final results atomically

VoxKey may perform a Provisional Decode incrementally in memory while the user speaks, but it does not display or insert provisional decoder text. Release reconciles that work into one Final Result, validates the Editing Intent, and performs Text Delivery atomically or invokes the Safety Net; cancellation discards the decoder state with the Ephemeral Audio. This reduces post-release latency and bounds audio memory without exposing unstable revisions or mutating the destination before VoxKey can prove that the original editing context remains safe.
