---
status: accepted
---

# Set the hardware floor from release evidence

VoxKey supports Apple Silicon, but the phrase does not automatically promise acceptable behavior on every chip generation and memory configuration. The exact minimum chip and unified-memory requirement are set from evidence gathered with the release candidate. Original M1 and 8 GB configurations are useful test candidates, not mandatory design baselines.

VoxKey does not reduce transcription quality, remove Provisional Decode, accept excessive post-release latency, unload the model so aggressively that Always Ready becomes misleading, or complicate the architecture merely to retain older hardware. If the compressed Default Model provides the complete core experience on an 8 GB M1, that configuration may be supported. If it does not, the published requirement moves upward and explains why.

The full 1.51 GB Model Override is labeled as recommending at least 16 GB of unified memory. VoxKey may warn below that recommendation but does not silently substitute another model. Model activation remains transactional: the existing working model stays active until a replacement package verifies and warms successfully.
