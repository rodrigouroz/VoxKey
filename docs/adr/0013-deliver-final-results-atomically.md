---
status: accepted
---

# Deliver final results atomically

VoxKey may perform a Provisional Decode incrementally in memory while the user speaks, and may display completed acoustic phrases and speculative predictions from unfinished audio in the nonactivating Status Overlay. Preview inference uses bounded copies of audio, yields to authoritative phrase and final decodes, and never retires audio or feeds predictions back into recognition, and no text is inserted into the Destination during capture. Release reconciles that work into one Final Result, validates the Editing Intent, and performs Text Delivery atomically or invokes the Safety Net; cancellation discards the decoder state with the Ephemeral Audio. This reduces post-release latency and bounds audio memory without mutating the destination before VoxKey can prove that the original editing context remains safe.
