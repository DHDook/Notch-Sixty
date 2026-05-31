---
name: Atomic float helpers
description: File-private float↔Int32 bit-cast helpers used in every DSP file.
---

Each DSP file that uses `ManagedAtomic<Int32>` to carry Float values defines its own
file-private helper pair with a unique suffix to avoid Swift's "redeclaration" error
(functions in the same module share a global namespace even when file-private):

| File | Suffix | Helpers |
|------|--------|---------|
| DynamicsProcessor.swift | (none) | `floatBits` / `bitsToFloat` |
| StereoWidener.swift      | W      | `floatBitsW` / `bitsToFloatW` |
| LoudnessMatchProcessor.swift | L | `floatBitsL` / `bitsToFloatL` |

**Why:** Swift file-private is per-file, not per-type; two files in the same module with identically named file-private free functions still collide at link time.

**How to apply:** Any new DSP file that needs float atomics must pick a new unique suffix and define its own pair at the bottom of the file.
