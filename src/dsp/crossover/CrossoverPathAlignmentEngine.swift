// CrossoverPathAlignmentEngine.swift
//
// Per-path delay alignment for Active Crossover to eliminate summed-response notches
// when different paths have different latencies (e.g., due to Option 3 escalation).
//
// Mechanism:
// 1. Compute per-path latency: crossoverFilterDelay + eqChainMeasuredDelay
// 2. Find maxLatency across all active paths
// 3. Add compensating delay (maxLatency - pathLatency) to each faster path
// 4. Recompute on configuration/escalation changes

import Accelerate
import Foundation

/// Per-path latency information for alignment.
struct PathLatencyInfo: Sendable {
    /// Total latency for this path in samples.
    var totalLatencySamples: Int

    /// Crossover filter's characteristic group delay in samples (fixed for given design).
    var crossoverFilterDelaySamples: Int

    /// EQ chain's measured characteristic delay in samples (from Option 3 or all-pass fitting).
    var eqChainMeasuredDelaySamples: Int

    /// Whether this path is currently active (enabled in output channel matrix).
    var isActive: Bool
}

/// Compensating delay line for a single path.
final class PathDelayLine: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writePos: Int = 0
    private var readPos: Int = 0
    private var currentDelaySamples: Int = 0

    init(maxDelaySamples: Int, maxFrameCount: Int) {
        self.capacity = maxDelaySamples + maxFrameCount
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Sets the delay for this path.
    func setDelay(samples: Int) {
        currentDelaySamples = samples
    }

    /// Processes audio through the delay line.
    @inline(__always)
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard currentDelaySamples > 0 else {
            // Pass-through when no delay
            memcpy(output, input, frameCount * MemoryLayout<Float>.size)
            return
        }

        // Write input to buffer
        for i in 0..<frameCount {
            buffer[writePos] = input[i]
            writePos = (writePos + 1) % capacity
        }

        // Read from buffer with delay
        // The read position should be delayed by currentDelaySamples
        let delayedReadPos = (writePos + capacity - currentDelaySamples) % capacity
        for i in 0..<frameCount {
            let readIdx = (delayedReadPos + i) % capacity
            output[i] = buffer[readIdx]
        }

        readPos = writePos
    }

    /// Resets the delay line.
    func reset() {
        vDSP_vclr(buffer, 1, vDSP_Length(capacity))
        writePos = 0
        readPos = 0
    }
}

/// Engine for aligning crossover path delays to eliminate summed-response notches.
final class CrossoverPathAlignmentEngine: @unchecked Sendable {

    // MARK: - Configuration

    private let sampleRate: Double
    private let maxFrameCount: Int

    // MARK: - State

    /// Per-path delay lines (indexed by channel index in output channel matrix).
    private var delayLines: [Int: PathDelayLine] = [:]

    /// Current per-path latency information.
    private var pathLatencies: [Int: PathLatencyInfo] = [:]

    /// Maximum delay across all paths (in samples).
    private var maxLatencySamples: Int = 0

    /// Whether alignment is currently active (more than one active path).
    private var isActive: Bool = false

    /// Lock for state updates.
    private let stateLock = NSLock()

    // MARK: - Initialization

    init(sampleRate: Double, maxFrameCount: Int) {
        self.sampleRate = sampleRate
        self.maxFrameCount = maxFrameCount
    }

    // MARK: - Public API

    /// Updates path latency information and recomputes alignment.
    ///
    /// - Parameters:
    ///   - pathLatencies: Per-path latency info keyed by channel index.
    func updatePathLatencies(_ pathLatencies: [Int: PathLatencyInfo]) {
        stateLock.lock()
        defer { stateLock.unlock() }

        self.pathLatencies = pathLatencies

        // Count active paths
        let activePaths = pathLatencies.values.filter { $0.isActive }
        isActive = activePaths.count > 1

        guard isActive else {
            // Single path or disabled - no alignment needed
            maxLatencySamples = 0
            return
        }

        // Find maximum latency across active paths
        maxLatencySamples = activePaths.map { $0.totalLatencySamples }.max() ?? 0

        // Update compensating delays for each path
        for (channelIndex, latencyInfo) in pathLatencies {
            guard latencyInfo.isActive else { continue }

            let compensatingDelay = maxLatencySamples - latencyInfo.totalLatencySamples
            let maxDelayNeeded = maxLatencySamples  // Worst case: path with zero latency

            // Ensure delay line exists
            if delayLines[channelIndex] == nil {
                delayLines[channelIndex] = PathDelayLine(
                    maxDelaySamples: maxDelayNeeded,
                    maxFrameCount: maxFrameCount
                )
            }

            // Update delay
            delayLines[channelIndex]?.setDelay(samples: compensatingDelay)
        }

        // Remove delay lines for inactive paths
        let activeIndices = Set(pathLatencies.keys.filter { pathLatencies[$0]!.isActive })
        for index in delayLines.keys where !activeIndices.contains(index) {
            delayLines.removeValue(forKey: index)
        }
    }

    /// Processes audio through the alignment engine for a specific path.
    ///
    /// - Parameters:
    ///   - channelIndex: The channel index in the output channel matrix.
    ///   - input: Input buffer.
    ///   - output: Output buffer.
    ///   - frameCount: Number of samples to process.
    @inline(__always)
    func process(channelIndex: Int,
                 input: UnsafePointer<Float>,
                 output: UnsafeMutablePointer<Float>,
                 frameCount: Int) {
        stateLock.lock()
        let active = isActive
        stateLock.unlock()

        guard active else {
            // Pass-through when alignment is inactive
            memcpy(output, input, frameCount * MemoryLayout<Float>.size)
            return
        }

        stateLock.lock()
        let delayLine = delayLines[channelIndex]
        stateLock.unlock()

        if let delayLine = delayLine {
            delayLine.process(input: input, output: output, frameCount: frameCount)
        } else {
            // No delay line for this path - pass-through
            memcpy(output, input, frameCount * MemoryLayout<Float>.size)
        }
    }

    /// Resets all delay lines.
    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        for delayLine in delayLines.values {
            delayLine.reset()
        }
    }

    /// Returns the effective system output latency after alignment (in milliseconds).
    var effectiveLatencyMs: Double {
        stateLock.lock()
        let maxLatency = maxLatencySamples
        stateLock.unlock()

        return Double(maxLatency) * 1000.0 / sampleRate
    }

    /// Returns whether alignment is currently active.
    var alignmentActive: Bool {
        stateLock.lock()
        let active = isActive
        stateLock.unlock()
        return active
    }

    /// Returns the current compensating delay for a specific path (in samples).
    func compensatingDelayForPath(channelIndex: Int) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let latencyInfo = pathLatencies[channelIndex], latencyInfo.isActive else {
            return 0
        }

        return maxLatencySamples - latencyInfo.totalLatencySamples
    }
}
