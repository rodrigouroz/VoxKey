---
status: accepted
---

# Use a rolling two-version macOS window

VoxKey supports the current public major macOS release and its immediate predecessor on Apple Silicon. Beta releases do not advance the window. As of August 2026 the minimum is macOS 26; when macOS 27 becomes public, versions 26 and 27 will be supported, and version 26 will be dropped when macOS 28 becomes public. This gives managed machines roughly a year to upgrade while avoiding indefinite compatibility constraints.

## Current implementation

The current package and app metadata require macOS 26. This minimum remains a floor even when a two-version window would otherwise include an older OS. New OS compatibility requires release evidence; the dates and future versions above describe the policy, not completed validation.
