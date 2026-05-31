---
name: Biquad DF2T convention
description: Coefficient format and DF2T update equation used throughout the DSP layer.
---

All biquad coefficient helpers return `(b0, b1, b2, na1, na2)` where:
- `na1 = +2·cos(w0) / a0`  (pre-negated −a1/a0)
- `na2 = −(1 − α) / a0`   (pre-negated −a2/a0)

DF2T state update (used in processBiquad and all inline equivalents):
```swift
let y = b0 * x + w1
w1 = b1 * x + na1 * y + w2
w2 = b2 * x + na2 * y
```

**Why:** Keeps the hot inner loop branchless; pre-negated na1/na2 means no sign flip at the adder.

**How to apply:** Any new filter stage must use the same convention. All coefficient helpers (lpfCoeffs, hpfCoeffs, bpfCoeffs) already follow it.
