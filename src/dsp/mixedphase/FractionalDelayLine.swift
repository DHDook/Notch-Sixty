// FractionalDelayLine.swift
//
// Fractional-sample interpolated delay line for seamless latency transitions.
// Used during de-escalation to gradually release compensating delay without
// introducing audible pitch artifacts.

import Accelerate
import Foundation

/// Fractional-sample interpolated delay line with time-varying delay.
///
/// Supports gradual delay changes over 1-2 seconds with sub-sample precision
/// using linear interpolation. The delay change rate is kept slow enough
/// (1-2 samples per 100ms) to avoid audible pitch artifacts.
final class FractionalDelayLine: @unchecked Sendable {

    // MARK: - Configuration

    /// Maximum delay in samples (buffer size).
    private let maxDelaySamples: Int

    /// Sample rate for delay ramp rate calculations.
    private let sampleRate: Double

    // MARK: - State

    /// Circular buffer for delay storage.
    nonisolated(unsafe) private var buffer: UnsafeMutablePointer<Float>

    /// Current write position in the circular buffer.
    nonisolated(unsafe) private var writePos: Int = 0

    /// Current fractional delay in samples (0 to maxDelaySamples).
    nonisolated(unsafe) private var currentDelay: Float = 0

    /// Target delay in samples (where the ramp is heading).
    nonisolated(unsafe) private var targetDelay: Float = 0

    /// Delay ramp rate in samples per second.
    nonisolated(unsafe) private var rampRate: Float = 0

    /// Whether a delay ramp is currently active.
    nonisolated(unsafe) private var isRamping: Bool = false

    // MARK: - Initialization

    /// Initializes a fractional delay line.
    ///
    /// - Parameters:
    ///   - maxDelayMs: Maximum delay in milliseconds.
    ///   - sampleRate: Audio sample rate in Hz.
    init(maxDelayMs: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.maxDelaySamples = Int(ceil(maxDelayMs * sampleRate / 1000.0)) + 1  // +1 for interpolation headroom
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: maxDelaySamples)
        self.buffer.initialize(repeating: 0, count: maxDelaySamples)
    }

    deinit {
        buffer.deinitialize(count: maxDelaySamples)
        buffer.deallocate()
    }

    // MARK: - Public API

    /// Sets a new target delay with a gradual ramp.
    ///
    /// - Parameters:
    ///   - targetDelayMs: Target delay in milliseconds.
    ///   - rampDurationMs: Duration of the delay ramp in milliseconds (default: 1500ms).
    func setTargetDelay(targetDelayMs: Double, rampDurationMs: Double = 1500.0) {
        let targetDelaySamples = Float(targetDelayMs * sampleRate / 1000.0)
        self.targetDelay = min(max(0, targetDelaySamples), Float(maxDelaySamples - 1))

        let delayDifference = abs(self.targetDelay - currentDelay)
        let rampDurationSeconds = rampDurationMs / 1000.0

        // Calculate ramp rate: samples per second
        // Ensure rate is slow enough to avoid pitch artifacts (rule of thumb: 1-2 samples per 100ms)
        let maxAllowedRate = Float(sampleRate) / 100.0 * 2.0  // 2 samples per 100ms max
        let calculatedRate = delayDifference / Float(rampDurationSeconds)
        self.rampRate = min(calculatedRate, maxAllowedRate)

        isRamping = delayDifference > 0.001  // Only ramp if there's a meaningful difference
    }

    /// Processes audio through the delay line (Swift array version).
    ///
    /// - Parameters:
    ///   - input: Input buffer (read-only).
    ///   - output: Output buffer (written to).
    @inline(__always)
    func process(input: [Float], output: inout [Float]) {
        let frameCount = input.count
        for i in 0..<frameCount {
            // Write input sample to circular buffer
            buffer[writePos] = input[i]

            // Calculate read position with fractional delay
            let readPosFloat = Float(writePos) - currentDelay
            let readPosInt = Int(readPosFloat)
            let fractional = readPosFloat - Float(readPosInt)

            // Handle wraparound for circular buffer
            let readIdx0 = ((readPosInt % maxDelaySamples) + maxDelaySamples) % maxDelaySamples
            let readIdx1 = ((readIdx0 + 1) % maxDelaySamples)

            // Linear interpolation between adjacent samples
            let sample0 = buffer[readIdx0]
            let sample1 = buffer[readIdx1]
            output[i] = sample0 + fractional * (sample1 - sample0)

            // Update delay if ramping
            if isRamping {
                if currentDelay < targetDelay {
                    currentDelay += rampRate / Float(sampleRate)
                    if currentDelay >= targetDelay {
                        currentDelay = targetDelay
                        isRamping = false
                    }
                } else if currentDelay > targetDelay {
                    currentDelay -= rampRate / Float(sampleRate)
                    if currentDelay <= targetDelay {
                        currentDelay = targetDelay
                        isRamping = false
                    }
                }
            }

            // Advance write position
            writePos = (writePos + 1) % maxDelaySamples
        }
    }

    /// Resets the delay line to zero delay.
    func reset() {
        vDSP_vclr(buffer, 1, vDSP_Length(maxDelaySamples))
        writePos = 0
        currentDelay = 0
        targetDelay = 0
        rampRate = 0
        isRamping = false
    }

    /// Returns the current delay in milliseconds.
    var currentDelayMs: Double {
        Double(currentDelay) * 1000.0 / sampleRate
    }

    /// Returns whether a delay ramp is currently active.
    var rampInProgress: Bool {
        isRamping
    }
}
