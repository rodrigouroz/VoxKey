---
status: accepted
---

# Keep only one volatile last result

For the Core Release, VoxKey keeps at most one unavailable, unconfirmed, or failed-delivery transcript as the Last Result in volatile memory. A newer retained result replaces it, and quit, crash, or restart loses it; VoxKey does not persist a recovery queue or apply a Recovery Window. The Safety Net supports Return for validated Recovery Delivery and explicit Command-C copying, but never writes the Last Result to the pasteboard automatically. This supersedes ADR-0002 and favors a small, inspectable recovery state over durable history.
