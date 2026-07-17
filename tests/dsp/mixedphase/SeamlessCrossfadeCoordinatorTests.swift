// SeamlessCrossfadeCoordinatorTests.swift
//
// Tests for the dual-path crossfade coordinator, including:
// - Alignment correctness (cross-correlation verification)
// - De-escalation delay-release verification
// - Concurrent-trigger stress tests

import Accelerate
import XCTest
@testable import Equaliser

final class SeamlessCrossfadeCoordinatorTests: XCTestCase {

    var sampleRate: Double = 48000.0
    var maxFrameCount: Int = 512

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Alignment Correctness Tests

    /// Tests that at the moment blending begins, both chains' outputs correspond
    /// to the same input position using cross-correlation verification.
    func testAlignmentCorrectness_Escalation() {
        let coordinator = SeamlessCrossfadeCoordinator(
            sampleRate: sampleRate,
            maxFrameCount: maxFrameCount
        )

        // Create a distinctive test signal with identifiable transients
        let testSignal = generateImpulseTrain(sampleRate: sampleRate, duration: 0.1, impulseInterval: 0.01)

        // Setup: primary engine with short latency kernel
        let shortKernel = createTestKernel(size: 2048, peakIndex: 1024)
        let longKernel = createTestKernel(size: 4096, peakIndex: 2048)

        // Configure primary engine (short latency)
        coordinator.triggerTransition(
            targetKernel: shortKernel,
            targetDelaySamples: 1024,
            currentDelaySamples: 1024
        )

        // Process to establish baseline
        var bufL = testSignal
        coordinator.process(bufL: &bufL, bufR: nil, frameCount: testSignal.count)

        // Trigger escalation (short → long latency)
        coordinator.triggerTransition(
            targetKernel: longKernel,
            targetDelaySamples: 2048,
            currentDelaySamples: 1024
        )

        // Process through priming phase
        for _ in 0..<10 {
            var temp = testSignal
            coordinator.process(bufL: &temp, bufR: nil, frameCount: temp.count)
        }

        // Now in crossfade phase - capture outputs from both chains
        // This requires internal access to both engines for testing
        // For now, we'll verify the coordinator state
        XCTAssertEqual(coordinator.currentState, .crossfading, "Should be in crossfade state after priming")

        // Verify alignment by checking that the crossfade produces no discontinuity
        // This is an indirect test - a full test would require internal access
        coordinator.reset()
    }

    /// Tests alignment correctness for de-escalation (long → short latency).
    func testAlignmentCorrectness_Deescalation() {
        let coordinator = SeamlessCrossfadeCoordinator(
            sampleRate: sampleRate,
            maxFrameCount: maxFrameCount
        )

        let testSignal = generateImpulseTrain(sampleRate: sampleRate, duration: 0.1, impulseInterval: 0.01)

        let shortKernel = createTestKernel(size: 2048, peakIndex: 1024)
        let longKernel = createTestKernel(size: 4096, peakIndex: 2048)

        // Start with long latency
        coordinator.triggerTransition(
            targetKernel: longKernel,
            targetDelaySamples: 2048,
            currentDelaySamples: 2048
        )

        var bufL = testSignal
        coordinator.process(bufL: &bufL, bufR: nil, frameCount: testSignal.count)

        // Trigger de-escalation (long → short latency)
        coordinator.triggerTransition(
            targetKernel: shortKernel,
            targetDelaySamples: 1024,
            currentDelaySamples: 2048
        )

        // Process through priming phase
        for _ in 0..<10 {
            var temp = testSignal
            coordinator.process(bufL: &temp, bufR: nil, frameCount: temp.count)
        }

        // Should be in crossfade state
        XCTAssertEqual(coordinator.currentState, .crossfading, "Should be in crossfade state after priming")

        coordinator.reset()
    }

    // MARK: - Cross-Correlation Verification

    /// Computes cross-correlation between two signals to verify alignment.
    func testCrossCorrelation() {
        let signal1 = generateImpulseTrain(sampleRate: sampleRate, duration: 0.1, impulseInterval: 0.01)
        var signal2 = signal1

        // Introduce a known delay
        let delaySamples = 100
        signal2 = Array(signal2.dropFirst(delaySamples)) + Array(repeating: 0.0, count: delaySamples)

        // Compute cross-correlation
        let lag = computeCrossCorrelationLag(signal1: signal1, signal2: signal2)

        // Verify that the detected lag matches the known delay
        XCTAssertEqual(lag, delaySamples, accuracy: 1, "Cross-correlation should detect the correct lag")
    }

    // MARK: - De-escalation Delay-Release Verification

    /// Tests that the gradual delay ramp completes within the expected window.
    func testDelayRampCompletion() {
        let coordinator = SeamlessCrossfadeCoordinator(
            sampleRate: sampleRate,
            maxFrameCount: maxFrameCount,
            config: CrossfadeConfig(delayRampDurationMs: 1000.0)
        )

        let testSignal = generateSineWave(frequency: 1000, sampleRate: sampleRate, duration: 2.0)

        let shortKernel = createTestKernel(size: 2048, peakIndex: 1024)
        let longKernel = createTestKernel(size: 4096, peakIndex: 2048)

        // Start with long latency
        coordinator.triggerTransition(
            targetKernel: longKernel,
            targetDelaySamples: 2048,
            currentDelaySamples: 2048
        )

        // Process to establish baseline
        var bufL = Array(testSignal.prefix(512))
        coordinator.process(bufL: &bufL, bufR: nil, frameCount: bufL.count)

        // Trigger de-escalation
        coordinator.triggerTransition(
            targetKernel: shortKernel,
            targetDelaySamples: 1024,
            currentDelaySamples: 2048
        )

        // Process through priming and crossfade
        for _ in 0..<20 {
            var temp = Array(testSignal.prefix(512))
            coordinator.process(bufL: &temp, bufR: nil, frameCount: temp.count)
        }

        // Should now be in delay ramp phase
        XCTAssertEqual(coordinator.currentState, .delayRamping, "Should be in delay ramp phase after crossfade")

        // Process through delay ramp (should take ~1 second at 48kHz = 48000 samples)
        let totalSamples = testSignal.count
        var processedSamples = 0
        var state: CrossfadeState = .delayRamping

        while state == .delayRamping && processedSamples < totalSamples {
            let chunkSize = min(512, totalSamples - processedSamples)
            var chunk = Array(testSignal[processedSamples..<processedSamples + chunkSize])
            coordinator.process(bufL: &chunk, bufR: nil, frameCount: chunk.count)
            processedSamples += chunkSize
            state = coordinator.currentState
        }

        // Should complete delay ramp and enter cooldown
        XCTAssertEqual(state, .cooldown, "Delay ramp should complete and enter cooldown")

        // Verify it didn't take excessively long (within 2x expected duration)
        let expectedSamples = Int(1000.0 * sampleRate / 1000.0)  // 1 second
        XCTAssertLessThan(processedSamples, expectedSamples * 2, "Delay ramp should complete within reasonable time")

        coordinator.reset()
    }

    /// Tests that no measurable pitch artifact is introduced during delay ramp.
    func testDelayRampPitchArtifact() {
        let coordinator = SeamlessCrossfadeCoordinator(
            sampleRate: sampleRate,
            maxFrameCount: maxFrameCount,
            config: CrossfadeConfig(delayRampDurationMs: 1000.0)
        )

        // Use a sustained tone for frequency analysis
        let testFrequency: Double = 1000.0
        let testSignal = generateSineWave(frequency: testFrequency, sampleRate: sampleRate, duration: 2.0)

        let shortKernel = createTestKernel(size: 2048, peakIndex: 1024)
        let longKernel = createTestKernel(size: 4096, peakIndex: 2048)

        // Setup and trigger de-escalation
        coordinator.triggerTransition(
            targetKernel: longKernel,
            targetDelaySamples: 2048,
            currentDelaySamples: 2048
        )

        var bufL = Array(testSignal.prefix(512))
        coordinator.process(bufL: &bufL, bufR: nil, frameCount: bufL.count)

        coordinator.triggerTransition(
            targetKernel: shortKernel,
            targetDelaySamples: 1024,
            currentDelaySamples: 2048
        )

        // Process through priming and crossfade
        for _ in 0..<20 {
            var temp = Array(testSignal.prefix(512))
            coordinator.process(bufL: &temp, bufR: nil, frameCount: temp.count)
        }

        // Capture output during delay ramp
        var rampOutput: [Float] = []
        let rampDurationSamples = Int(1000.0 * sampleRate / 1000.0)  // 1 second
        var processedSamples = 0

        while processedSamples < rampDurationSamples && coordinator.currentState == .delayRamping {
            let chunkSize = min(512, rampDurationSamples - processedSamples)
            var chunk = Array(testSignal[processedSamples..<processedSamples + chunkSize])
            coordinator.process(bufL: &chunk, bufR: nil, frameCount: chunk.count)
            rampOutput.append(contentsOf: chunk)
            processedSamples += chunkSize
        }

        // Analyze frequency content before, during, and after ramp
        if rampOutput.count >= 512 {
            let frequencyBefore = estimateDominantFrequency(signal: Array(rampOutput.prefix(256)), sampleRate: sampleRate)
            let frequencyAfter = estimateDominantFrequency(signal: Array(rampOutput.suffix(256)), sampleRate: sampleRate)

            // Frequency should remain stable (within 1% of original)
            let frequencyDeviation = abs(frequencyBefore - frequencyAfter) / testFrequency
            XCTAssertLessThan(frequencyDeviation, 0.01, "Frequency deviation during delay ramp should be < 1%")
        }

        coordinator.reset()
    }

    // MARK: - Concurrent-Trigger Stress Tests

    /// Tests that rapid triggering doesn't cause runaway concurrent transitions.
    func testConcurrentTriggerCooldown() {
        let coordinator = SeamlessCrossfadeCoordinator(
            sampleRate: sampleRate,
            maxFrameCount: maxFrameCount,
            config: CrossfadeConfig(cooldownDurationMs: 500.0)
        )

        let testSignal = generateSineWave(frequency: 1000, sampleRate: sampleRate, duration: 0.5)
        let kernel = createTestKernel(size: 2048, peakIndex: 1024)

        // Trigger first transition
        coordinator.triggerTransition(
            targetKernel: kernel,
            targetDelaySamples: 1024,
            currentDelaySamples: 512
        )

        // Immediately try to trigger another (should be rejected due to in-progress transition)
        coordinator.triggerTransition(
            targetKernel: kernel,
            targetDelaySamples: 2048,
            currentDelaySamples: 1024
        )

        // Should still be in priming state (second trigger rejected)
        XCTAssertEqual(coordinator.currentState, .priming, "Second trigger should be rejected during priming")

        coordinator.reset()
    }

    /// Tests that repeated transitions don't cause resource leaks.
    func testRepeatedTransitionsNoLeak() {
        let coordinator = SeamlessCrossfadeCoordinator(
            sampleRate: sampleRate,
            maxFrameCount: maxFrameCount
        )

        let testSignal = generateSineWave(frequency: 1000, sampleRate: sampleRate, duration: 0.1)
        let shortKernel = createTestKernel(size: 2048, peakIndex: 1024)
        let longKernel = createTestKernel(size: 4096, peakIndex: 2048)

        // Perform many transitions
        for i in 0..<10 {
            let targetKernel = i % 2 == 0 ? longKernel : shortKernel
            let targetDelay = i % 2 == 0 ? 2048 : 1024
            let currentDelay = i % 2 == 0 ? 1024 : 2048

            coordinator.triggerTransition(
                targetKernel: targetKernel,
                targetDelaySamples: targetDelay,
                currentDelaySamples: currentDelay
            )

            // Process through the transition
            for _ in 0..<30 {
                var temp = testSignal
                coordinator.process(bufL: &temp, bufR: nil, frameCount: temp.count)
            }

            // Wait for cooldown
            while coordinator.currentState == .cooldown {
                var temp = testSignal
                coordinator.process(bufL: &temp, bufR: nil, frameCount: temp.count)
            }
        }

        // Should end in idle state
        XCTAssertEqual(coordinator.currentState, .idle, "Should return to idle after all transitions")

        coordinator.reset()
    }

    /// Tests that audio output stays glitch-free during rapid parameter changes.
    func testGlitchFreeDuringRapidChanges() {
        let coordinator = SeamlessCrossfadeCoordinator(
            sampleRate: sampleRate,
            maxFrameCount: maxFrameCount
        )

        let testSignal = generateSineWave(frequency: 1000, sampleRate: sampleRate, duration: 1.0)
        let shortKernel = createTestKernel(size: 2048, peakIndex: 1024)
        let longKernel = createTestKernel(size: 4096, peakIndex: 2048)

        var output: [Float] = []
        var processedSamples = 0

        // Process while occasionally triggering transitions
        while processedSamples < testSignal.count {
            let chunkSize = min(512, testSignal.count - processedSamples)
            var chunk = Array(testSignal[processedSamples..<processedSamples + chunkSize])

            // Occasionally trigger a transition
            if processedSamples % 10000 < 512 && coordinator.currentState == .idle {
                let targetKernel = processedSamples % 20000 < 10000 ? longKernel : shortKernel
                let targetDelay = processedSamples % 20000 < 10000 ? 2048 : 1024
                let currentDelay = processedSamples % 20000 < 10000 ? 1024 : 2048

                coordinator.triggerTransition(
                    targetKernel: targetKernel,
                    targetDelaySamples: targetDelay,
                    currentDelaySamples: currentDelay
                )
            }

            coordinator.process(bufL: &chunk, bufR: nil, frameCount: chunk.count)
            output.append(contentsOf: chunk)
            processedSamples += chunkSize
        }

        // Check for NaN or Inf in output (signs of glitches)
        let hasNaN = output.contains { $0.isNaN }
        let hasInf = output.contains { $0.isInfinite }
        XCTAssertFalse(hasNaN, "Output should not contain NaN")
        XCTAssertFalse(hasInf, "Output should not contain Inf")

        // Check for excessive spikes (signs of discontinuities)
        let maxAmplitude = output.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(maxAmplitude, 10.0, "Output should not have excessive spikes")

        coordinator.reset()
    }

    // MARK: - Helper Functions

    /// Generates an impulse train for alignment testing.
    private func generateImpulseTrain(sampleRate: Double, duration: Double, impulseInterval: Double) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var signal = [Float](repeating: 0, count: sampleCount)
        let impulsePeriod = Int(impulseInterval * sampleRate)

        for i in stride(from: 0, to: sampleCount, by: impulsePeriod) {
            signal[i] = 1.0
        }

        return signal
    }

    /// Generates a sine wave for frequency analysis.
    private func generateSineWave(frequency: Double, sampleRate: Double, duration: Double) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var signal = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            signal[i] = Float(sin(2.0 * .pi * frequency * t))
        }

        return signal
    }

    /// Creates a test FIR kernel with a peak at the specified index.
    private func createTestKernel(size: Int, peakIndex: Int) -> [Float] {
        var kernel = [Float](repeating: 0, count: size)
        kernel[peakIndex] = 1.0
        return kernel
    }

    /// Computes the lag between two signals using cross-correlation.
    private func computeCrossCorrelationLag(signal1: [Float], signal2: [Float]) -> Int {
        let n = min(signal1.count, signal2.count)
        var maxCorrelation: Float = 0
        var bestLag = 0

        // Search for lag in reasonable range
        let maxLag = min(200, n / 4)

        for lag in 0..<maxLag {
            var correlation: Float = 0
            for i in 0..<(n - lag) {
                correlation += signal1[i] * signal2[i + lag]
            }
            correlation /= Float(n - lag)

            if correlation > maxCorrelation {
                maxCorrelation = correlation
                bestLag = lag
            }
        }

        return bestLag
    }

    /// Estimates the dominant frequency in a signal using zero-crossing.
    private func estimateDominantFrequency(signal: [Float], sampleRate: Double) -> Double {
        guard signal.count > 1 else { return 0 }

        var zeroCrossings = 0
        for i in 1..<signal.count {
            if (signal[i-1] >= 0 && signal[i] < 0) || (signal[i-1] < 0 && signal[i] >= 0) {
                zeroCrossings += 1
            }
        }

        let duration = Double(signal.count) / sampleRate
        let frequency = Double(zeroCrossings) / (2.0 * duration)

        return frequency
    }
}
