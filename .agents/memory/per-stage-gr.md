---
name: Per-stage GR chain
description: How 8-channel gain-reduction metering flows from DSP to UI.
---

## Chain

1. **DynamicsProcessor** — 8 `ManagedAtomic<Int32>` (floatBits) written at end of each `process()` call:
   `_deEsserGRBits`, `_mbLowGRBits`, `_mbMidGRBits`, `_mbHighGRBits`,
   `_compGRBits`, `_expGRBits`, `_clipperGRBits`, `_gainReductionBits` (limiter).

2. **DynamicsProcessor public vars** — one computed property per stage reading the atomic.

3. **RenderPipeline** — 8 forwarding vars reading `callbackContext?.dynamicsProcessor.<stageVar>`.

4. **EqualiserStore** — 8 vars reading `routingCoordinator.pipelineManager.renderPipeline?.<stageVar>`.

5. **DynamicsInlineView** — 60 Hz timer, instant attack / 50 ms release ballistics, writes @State vars.

## Clipper peak-hold
`clipperPeakHoldFrames` counts down from 120 (= 2 s × 60 Hz). While > 0, `clipperPeakGR` is shown as a 1 px white peak-hold segment above the fill bar.

**Why:** Clipper is a transient device; peak-hold makes brief engagements visible.

**How to apply:** Any new stage meter should use the same instant-attack/50 ms-release ballistic pattern from `updateMeters()` in `DynamicsInlineView`.
