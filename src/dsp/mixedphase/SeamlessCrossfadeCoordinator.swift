// SeamlessCrossfadeCoordinator.swift
//
// Dual-path crossfade coordinator for seamless latency transitions in
// mixed-phase EQ. Manages concurrent DSP chains with alignment delay
// and equal-power crossfading to eliminate transients during escalation/de-escalation.

import Accelerate
import Atomics
import Foundation

/// Transition state for the crossfade coordinator.
enum CrossfadeState: Sendable {
    case idle                      // No transition in progress
    case preparingTransition       // Transition reserved, preparing secondary engine (outside lock)
    case priming                   // New chain is priming (accumulating startup hops)
    case crossfading               // Active crossfade between old and new chains
    case delayRamping              // Post-crossfade delay ramp (de-escalation only)
    case cooldown                  // Post-transition cooldown period
}

/// Transition direction for latency changes.
enum TransitionDirection: Sendable {
    case escalation    // Short → long latency (old chain gets temporary delay)
    case deescalation  // Long → short latency (new chain gets temporary delay + fractional ramp)
}

/// Configuration for the crossfade coordinator.
struct CrossfadeConfig: Sendable {
    /// Crossfade duration in milliseconds (default: 100ms).
    var crossfadeDurationMs: Double = 100.0

    /// Delay ramp duration in milliseconds for de-escalation (default: 1500ms).
    var delayRampDurationMs: Double = 1500.0

    /// Cooldown duration in milliseconds after transition (default: 500ms).
    var cooldownDurationMs: Double = 500.0

    /// Maximum alignment delay in milliseconds (for fixed-length compensation).
    var maxAlignmentDelayMs: Double = 200.0
}

/// Coordinator for seamless dual-path crossfade during latency transitions.
///
/// Manages two concurrent LinearPhaseEQEngine instances with proper alignment
/// and crossfading to eliminate transients when the adaptive excess-phase corrector
/// escalates or de-escalates.
final class SeamlessCrossfadeCoordinator: @unchecked Sendable {

    // MARK: - Configuration

    private let config: CrossfadeConfig
    private let sampleRate: Double
    private let maxFrameCount: Int

    // MARK: - State

    /// Current transition state.
    private var state: CrossfadeState = .idle

    /// Current transition direction (nil when idle).
    private var direction: TransitionDirection? = nil

    /// Cooldown timer (samples remaining).
    nonisolated(unsafe) private var cooldownSamplesRemaining: Int = 0

    /// Crossfade progress (0.0 to 1.0).
    nonisolated(unsafe) private var crossfadeProgress: Float = 0

    /// DSP chain A (one of two concurrent chains).
    private let engineA: LinearPhaseEQEngine

    /// DSP chain B (one of two concurrent chains).
    private let engineB: LinearPhaseEQEngine

    /// Which engine is currently the primary (active) chain.
    private var primaryEngineIndex: Int = 0  // 0 = engineA, 1 = engineB

    /// Fractional delay line for de-escalation delay ramp.
    private let fractionalDelay: FractionalDelayLine

    /// Fixed alignment delay buffer (for the faster chain during crossfade).
    nonisolated(unsafe) private var alignmentDelayBuffer: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var alignmentDelayWritePos: Int = 0
    nonisolated(unsafe) private var alignmentDelayReadPos: Int = 0
    private let alignmentDelaySize: Int

    /// Startup hop counter for priming the new chain.
    nonisolated(unsafe) private var primingHopsRemaining: Int = 0

    /// Lock-free state management.
    private let stateLock = NSLock()

    // MARK: - Initialization

    init(sampleRate: Double, maxFrameCount: Int, config: CrossfadeConfig = CrossfadeConfig()) {
        self.sampleRate = sampleRate
        self.maxFrameCount = maxFrameCount
        self.config = config

        self.engineA = LinearPhaseEQEngine(maxFrameCount: maxFrameCount)
        self.engineB = LinearPhaseEQEngine(maxFrameCount: maxFrameCount)

        // Fractional delay line sized for maximum alignment delay + ramp headroom
        let maxDelayMs = config.maxAlignmentDelayMs + config.delayRampDurationMs
        self.fractionalDelay = FractionalDelayLine(maxDelayMs: maxDelayMs, sampleRate: sampleRate)

        // Fixed alignment delay buffer
        // Derive from the real maximum, not a fixed ms budget that doesn't scale
        // with sample rate or adaptive kernel sizing.
        let maxPossibleKernelDelaySamples = 32768 / 2   // half of the largest adaptive kernel size
        self.alignmentDelaySize = maxPossibleKernelDelaySamples + maxFrameCount
        self.alignmentDelayBuffer = UnsafeMutablePointer<Float>.allocate(capacity: alignmentDelaySize)
        self.alignmentDelayBuffer.initialize(repeating: 0, count: alignmentDelaySize)
    }

    deinit {
        alignmentDelayBuffer.deinitialize(count: alignmentDelaySize)
        alignmentDelayBuffer.deallocate()
    }

    // MARK: - Public API

    /// Triggers a transition to a new latency state.
    ///
    /// - Parameters:
    ///   - targetKernel: Target FIR kernel for the new state.
    ///   - targetDelaySamples: Target latency in samples for the new state.
    ///   - currentDelaySamples: Current latency in samples.
    func triggerTransition(
        targetKernel: [Float],
        targetDelaySamples: Int,
        currentDelaySamples: Int
    ) {
        stateLock.lock()
        guard state == .idle else { stateLock.unlock(); return }
        state = .preparingTransition  // Reserve the transition, block re-entry
        stateLock.unlock()

        // Determine direction
        let direction: TransitionDirection = targetDelaySamples > currentDelaySamples ? .escalation : .deescalation
        let secondaryIndex = 1 - primaryEngineIndex
        let secondaryEngine = secondaryIndex == 0 ? engineA : engineB

        // Expensive work: fully outside any lock.
        secondaryEngine.updateIRFromKernel(leftKernel: targetKernel, rightKernel: targetKernel, sampleRate: sampleRate)

        let latencyDifference = abs(targetDelaySamples - currentDelaySamples)

        // Fast finalization: back under the lock only for simple assignments.
        stateLock.lock()
        self.direction = direction
        state = .priming
        primingHopsRemaining = 2
        stateLock.unlock()

        if direction == .deescalation {
            let alignmentDelayMs = Double(latencyDifference) * 1000.0 / sampleRate
            fractionalDelay.setTargetDelay(targetDelayMs: alignmentDelayMs, rampDurationMs: config.delayRampDurationMs)
        }
    }

    /// Processes audio through the coordinator.
    ///
    /// - Parameters:
    ///   - bufL: Left channel buffer (in-place).
    ///   - bufR: Right channel buffer (in-place, optional).
    ///   - frameCount: Number of samples to process.
    @inline(__always)
    func process(bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>?, frameCount: Int) {
        stateLock.lock()
        let currentState = state
        let currentDirection = direction
        stateLock.unlock()

        switch currentState {
        case .idle:
            // Single-path processing through primary engine only
            let primaryEngine = primaryEngineIndex == 0 ? engineA : engineB
            primaryEngine.process(bufL: bufL, bufR: bufR, frameCount: frameCount)

        case .preparingTransition:
            // Transition is being prepared on background thread - treat as idle
            // Single-path processing through primary engine only
            let primaryEngine = primaryEngineIndex == 0 ? engineA : engineB
            primaryEngine.process(bufL: bufL, bufR: bufR, frameCount: frameCount)

        case .priming:
            // Prime secondary engine while processing through primary
            let primaryEngine = primaryEngineIndex == 0 ? engineA : engineB
            let secondaryEngine = primaryEngineIndex == 0 ? engineB : engineA
            primaryEngine.process(bufL: bufL, bufR: bufR, frameCount: frameCount)

            // Feed same input to secondary for priming
            var tempL = [Float](repeating: 0, count: frameCount)
            var tempR: [Float]?
            if let bufR = bufR {
                tempR = [Float](repeating: 0, count: frameCount)
                memcpy(&tempL, bufL, frameCount * MemoryLayout<Float>.size)
                memcpy(&tempR!, bufR, frameCount * MemoryLayout<Float>.size)
            } else {
                memcpy(&tempL, bufL, frameCount * MemoryLayout<Float>.size)
            }

            tempL.withUnsafeMutableBufferPointer { bufLPtr in
                if var tempR = tempR {
                    tempR.withUnsafeMutableBufferPointer { bufRPtr in
                        secondaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: bufRPtr.baseAddress!, frameCount: frameCount)
                    }
                } else {
                    secondaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: nil, frameCount: frameCount)
                }
            }

            // Check if priming complete
            stateLock.lock()
            primingHopsRemaining -= 1
            if primingHopsRemaining <= 0 {
                state = .crossfading
                crossfadeProgress = 0
            }
            stateLock.unlock()

        case .crossfading:
            processCrossfade(bufL: bufL, bufR: bufR, frameCount: frameCount, direction: currentDirection)

        case .delayRamping:
            processDelayRamp(bufL: bufL, bufR: bufR, frameCount: frameCount)

        case .cooldown:
            // Single-path processing through primary engine
            let primaryEngine = primaryEngineIndex == 0 ? engineA : engineB
            primaryEngine.process(bufL: bufL, bufR: bufR, frameCount: frameCount)

            // Update cooldown timer
            stateLock.lock()
            cooldownSamplesRemaining -= frameCount
            if cooldownSamplesRemaining <= 0 {
                state = .idle
                direction = nil
            }
            stateLock.unlock()
        }
    }

    /// Resets the coordinator to idle state.
    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        state = .idle
        direction = nil
        cooldownSamplesRemaining = 0
        crossfadeProgress = 0
        primingHopsRemaining = 0

        engineA.reset()
        engineB.reset()
        fractionalDelay.reset()

        vDSP_vclr(alignmentDelayBuffer, 1, vDSP_Length(alignmentDelaySize))
        alignmentDelayWritePos = 0
        alignmentDelayReadPos = 0
    }

    /// Returns the current transition state.
    var currentState: CrossfadeState {
        stateLock.lock()
        let s = state
        stateLock.unlock()
        return s
    }

    // MARK: - Private Methods

    @inline(__always)
    private func processCrossfade(
        bufL: UnsafeMutablePointer<Float>,
        bufR: UnsafeMutablePointer<Float>?,
        frameCount: Int,
        direction: TransitionDirection?
    ) {
        guard let direction = direction else {
            // Fallback to single-path if direction is lost
            let primaryEngine = primaryEngineIndex == 0 ? engineA : engineB
            primaryEngine.process(bufL: bufL, bufR: bufR, frameCount: frameCount)
            stateLock.lock()
            state = .idle
            stateLock.unlock()
            return
        }

        let primaryEngine = primaryEngineIndex == 0 ? engineA : engineB
        let secondaryEngine = primaryEngineIndex == 0 ? engineB : engineA

        // Process both chains
        var primaryL = [Float](repeating: 0, count: frameCount)
        var primaryR: [Float]?
        if let bufR = bufR {
            primaryR = [Float](repeating: 0, count: frameCount)
            memcpy(&primaryL, bufL, frameCount * MemoryLayout<Float>.size)
            memcpy(&primaryR!, bufR, frameCount * MemoryLayout<Float>.size)
        } else {
            memcpy(&primaryL, bufL, frameCount * MemoryLayout<Float>.size)
        }

        var secondaryL = [Float](repeating: 0, count: frameCount)
        var secondaryR: [Float]?
        if let bufR = bufR {
            secondaryR = [Float](repeating: 0, count: frameCount)
            memcpy(&secondaryL, bufL, frameCount * MemoryLayout<Float>.size)
            memcpy(&secondaryR!, bufR, frameCount * MemoryLayout<Float>.size)
        } else {
            memcpy(&secondaryL, bufL, frameCount * MemoryLayout<Float>.size)
        }

        primaryL.withUnsafeMutableBufferPointer { bufLPtr in
            if var primaryR = primaryR {
                primaryR.withUnsafeMutableBufferPointer { bufRPtr in
                    primaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: bufRPtr.baseAddress!, frameCount: frameCount)
                }
            } else {
                primaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: nil, frameCount: frameCount)
            }
        }

        secondaryL.withUnsafeMutableBufferPointer { bufLPtr in
            if var secondaryR = secondaryR {
                secondaryR.withUnsafeMutableBufferPointer { bufRPtr in
                    secondaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: bufRPtr.baseAddress!, frameCount: frameCount)
                }
            } else {
                secondaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: nil, frameCount: frameCount)
            }
        }

        // Apply alignment delay to the faster chain
        let latencyDifference = abs(secondaryEngine.kernelDelaySamples - primaryEngine.kernelDelaySamples)

        switch direction {
        case .escalation:
            // Primary (old) is faster - delay it
            var delayedL = [Float](repeating: 0, count: frameCount)
            applyFixedAlignmentDelay(
                input: &primaryL,
                output: &delayedL,
                delaySamples: latencyDifference,
                frameCount: frameCount
            )
            primaryL = delayedL

            if var primaryR = primaryR {
                var delayedR = [Float](repeating: 0, count: frameCount)
                applyFixedAlignmentDelay(
                    input: &primaryR,
                    output: &delayedR,
                    delaySamples: latencyDifference,
                    frameCount: frameCount
                )
                primaryR = delayedR
            }

        case .deescalation:
            // Secondary (new) is faster - delay it with fractional line
            fractionalDelay.process(input: secondaryL, output: &secondaryL)
            if var secondaryR = secondaryR {
                fractionalDelay.process(input: secondaryR, output: &secondaryR)
            }
        }

        // Equal-power crossfade
        let crossfadeStep = Float(frameCount) / Float(config.crossfadeDurationMs * sampleRate / 1000.0)

        for i in 0..<frameCount {
            // Equal-power crossfade curve: sin/cos for constant loudness
            let angle = crossfadeProgress * Float.pi / 2.0
            let gainOld = cos(angle)
            let gainNew = sin(angle)

            bufL[i] = gainOld * primaryL[i] + gainNew * secondaryL[i]
            if let bufR = bufR, let primaryR = primaryR, let secondaryR = secondaryR {
                bufR[i] = gainOld * primaryR[i] + gainNew * secondaryR[i]
            }

            crossfadeProgress += crossfadeStep
            if crossfadeProgress >= 1.0 {
                crossfadeProgress = 1.0
                break
            }
        }

        // Check if crossfade complete
        stateLock.lock()
        if crossfadeProgress >= 1.0 {
            if direction == .escalation {
                // Escalation: swap engines and go to cooldown
                swapEngines()
                state = .cooldown
                cooldownSamplesRemaining = Int(config.cooldownDurationMs * sampleRate / 1000.0)
            } else {
                // De-escalation: swap engines and enter delay ramp phase
                swapEngines()
                state = .delayRamping
            }
            crossfadeProgress = 0
        }
        stateLock.unlock()
    }

    @inline(__always)
    private func processDelayRamp(
        bufL: UnsafeMutablePointer<Float>,
        bufR: UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) {
        // Process through primary (now the faster, de-escalated chain)
        // with fractional delay ramping down
        let primaryEngine = primaryEngineIndex == 0 ? engineA : engineB
        var tempL = [Float](repeating: 0, count: frameCount)
        var tempR: [Float]?
        if let bufR = bufR {
            tempR = [Float](repeating: 0, count: frameCount)
            memcpy(&tempL, bufL, frameCount * MemoryLayout<Float>.size)
            memcpy(&tempR!, bufR, frameCount * MemoryLayout<Float>.size)
        } else {
            memcpy(&tempL, bufL, frameCount * MemoryLayout<Float>.size)
        }

        tempL.withUnsafeMutableBufferPointer { bufLPtr in
            if var tempR = tempR {
                tempR.withUnsafeMutableBufferPointer { bufRPtr in
                    primaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: bufRPtr.baseAddress!, frameCount: frameCount)
                }
            } else {
                primaryEngine.process(bufL: bufLPtr.baseAddress!, bufR: nil, frameCount: frameCount)
            }
        }

        // Apply fractional delay ramp
        var outputL = [Float](repeating: 0, count: frameCount)
        fractionalDelay.process(input: tempL, output: &outputL)
        memcpy(bufL, &outputL, frameCount * MemoryLayout<Float>.size)

        if let bufR = bufR, let tempR = tempR {
            var outputR = [Float](repeating: 0, count: frameCount)
            fractionalDelay.process(input: tempR, output: &outputR)
            memcpy(bufR, &outputR, frameCount * MemoryLayout<Float>.size)
        }

        // Check if delay ramp complete
        stateLock.lock()
        if !fractionalDelay.rampInProgress {
            state = .cooldown
            cooldownSamplesRemaining = Int(config.cooldownDurationMs * sampleRate / 1000.0)
        }
        stateLock.unlock()
    }

    @inline(__always)
    private func applyFixedAlignmentDelay(
        input: inout [Float],
        output: inout [Float],
        delaySamples: Int,
        frameCount: Int
    ) {
        // Bounds check: if delay exceeds buffer capacity, fall back to hard transition
        // This is a defensive backstop against buffer-sizing assumptions going stale
        guard delaySamples < alignmentDelaySize else {
            // Hard transition: copy input directly to output without delay
            memcpy(&output, &input, frameCount * MemoryLayout<Float>.size)
            return
        }

        // Write input to alignment delay buffer
        for i in 0..<frameCount {
            alignmentDelayBuffer[alignmentDelayWritePos] = input[i]
            alignmentDelayWritePos = (alignmentDelayWritePos + 1) % alignmentDelaySize
        }

        // Read from buffer with delay
        for i in 0..<frameCount {
            let readIdx = (alignmentDelayReadPos + i) % alignmentDelaySize
            output[i] = alignmentDelayBuffer[readIdx]
        }

        alignmentDelayReadPos = (alignmentDelayReadPos + frameCount) % alignmentDelaySize
    }

    private func swapEngines() {
        // Swap which engine is primary
        primaryEngineIndex = 1 - primaryEngineIndex
    }
}
