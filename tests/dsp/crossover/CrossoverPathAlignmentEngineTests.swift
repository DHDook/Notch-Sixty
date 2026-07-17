// CrossoverPathAlignmentEngineTests.swift
//
// Tests for crossover path delay alignment engine.

import Accelerate
import XCTest
@testable import Equaliser

final class CrossoverPathAlignmentEngineTests: XCTestCase {

    var engine: CrossoverPathAlignmentEngine!
    let sampleRate: Double = 48000.0
    let maxFrameCount: Int = 512

    override func setUp() {
        super.setUp()
        engine = CrossoverPathAlignmentEngine(sampleRate: sampleRate, maxFrameCount: maxFrameCount)
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - No-Op Confirmation Tests

    func testSinglePathNoAlignment() {
        // Single path should not activate alignment
        let pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 100,
                crossoverFilterDelaySamples: 50,
                eqChainMeasuredDelaySamples: 50,
                isActive: true
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        XCTAssertFalse(engine.alignmentActive, "Alignment should not be active with single path")
        XCTAssertEqual(engine.effectiveLatencyMs, 0.0, "Effective latency should be 0 with single path")
    }

    func testDisabledAlignmentNoEffect() {
        // Empty path latencies (disabled) should not activate alignment
        engine.updatePathLatencies([:])

        XCTAssertFalse(engine.alignmentActive, "Alignment should not be active when disabled")
        XCTAssertEqual(engine.effectiveLatencyMs, 0.0, "Effective latency should be 0 when disabled")
    }

    func testPassThroughWhenInactive() {
        // When alignment is inactive, audio should pass through unchanged
        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        var output: [Float] = [0, 0, 0, 0, 0]

        engine.process(channelIndex: 0,
                      input: input,
                      output: &output,
                      frameCount: input.count)

        XCTAssertEqual(output, input, "Audio should pass through unchanged when alignment inactive")
    }

    // MARK: - Core Alignment Tests

    func testTwoPathAlignment() {
        // Two paths with different latencies should align to the maximum
        let pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 100,
                crossoverFilterDelaySamples: 50,
                eqChainMeasuredDelaySamples: 50,
                isActive: true
            ),
            1: PathLatencyInfo(
                totalLatencySamples: 200,
                crossoverFilterDelaySamples: 100,
                eqChainMeasuredDelaySamples: 100,
                isActive: true
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        XCTAssertTrue(engine.alignmentActive, "Alignment should be active with multiple paths")
        XCTAssertEqual(engine.effectiveLatencyMs, 200.0 / sampleRate * 1000.0, accuracy: 0.01,
                      "Effective latency should be max latency (200 samples)")

        // Check compensating delays
        let delay0 = engine.compensatingDelayForPath(channelIndex: 0)
        let delay1 = engine.compensatingDelayForPath(channelIndex: 1)

        XCTAssertEqual(delay0, 100, "Path 0 should have 100 samples compensating delay")
        XCTAssertEqual(delay1, 0, "Path 1 (max latency) should have 0 compensating delay")
    }

    func testThreePathAlignment() {
        // Three paths with different latencies should align to the maximum
        let pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 50,
                crossoverFilterDelaySamples: 25,
                eqChainMeasuredDelaySamples: 25,
                isActive: true
            ),
            1: PathLatencyInfo(
                totalLatencySamples: 150,
                crossoverFilterDelaySamples: 75,
                eqChainMeasuredDelaySamples: 75,
                isActive: true
            ),
            2: PathLatencyInfo(
                totalLatencySamples: 300,
                crossoverFilterDelaySamples: 150,
                eqChainMeasuredDelaySamples: 150,
                isActive: true
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        XCTAssertTrue(engine.alignmentActive, "Alignment should be active with multiple paths")
        XCTAssertEqual(engine.effectiveLatencyMs, 300.0 / sampleRate * 1000.0, accuracy: 0.01,
                      "Effective latency should be max latency (300 samples)")

        // Check compensating delays
        let delay0 = engine.compensatingDelayForPath(channelIndex: 0)
        let delay1 = engine.compensatingDelayForPath(channelIndex: 1)
        let delay2 = engine.compensatingDelayForPath(channelIndex: 2)

        XCTAssertEqual(delay0, 250, "Path 0 should have 250 samples compensating delay")
        XCTAssertEqual(delay1, 150, "Path 1 should have 150 samples compensating delay")
        XCTAssertEqual(delay2, 0, "Path 2 (max latency) should have 0 compensating delay")
    }

    func testInactivePathExcluded() {
        // Inactive paths should not participate in alignment
        let pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 100,
                crossoverFilterDelaySamples: 50,
                eqChainMeasuredDelaySamples: 50,
                isActive: true
            ),
            1: PathLatencyInfo(
                totalLatencySamples: 200,
                crossoverFilterDelaySamples: 100,
                eqChainMeasuredDelaySamples: 100,
                isActive: false  // Inactive
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        XCTAssertFalse(engine.alignmentActive, "Alignment should not be active with only one active path")
        XCTAssertEqual(engine.effectiveLatencyMs, 0.0, "Effective latency should be 0 with single active path")
    }

    // MARK: - Dynamic Recomputation Tests

    func testDynamicLatencyChange() {
        // Initial state: two paths
        var pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 100,
                crossoverFilterDelaySamples: 50,
                eqChainMeasuredDelaySamples: 50,
                isActive: true
            ),
            1: PathLatencyInfo(
                totalLatencySamples: 200,
                crossoverFilterDelaySamples: 100,
                eqChainMeasuredDelaySamples: 100,
                isActive: true
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 0), 100)
        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 1), 0)

        // Simulate Option 3 escalation on path 0 (increased latency)
        pathLatencies[0] = PathLatencyInfo(
            totalLatencySamples: 350,  // Increased from 100
            crossoverFilterDelaySamples: 50,
            eqChainMeasuredDelaySamples: 300,  // Option 3 added 250 samples
            isActive: true
        )

        engine.updatePathLatencies(pathLatencies)

        // After escalation, path 0 becomes the max latency path
        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 0), 0)
        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 1), 150)  // 350 - 200
        XCTAssertEqual(engine.effectiveLatencyMs, 350.0 / sampleRate * 1000.0, accuracy: 0.01)
    }

    func testDynamicDeescalation() {
        // Initial state: path 0 has Option 3 escalation (high latency)
        var pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 350,
                crossoverFilterDelaySamples: 50,
                eqChainMeasuredDelaySamples: 300,
                isActive: true
            ),
            1: PathLatencyInfo(
                totalLatencySamples: 200,
                crossoverFilterDelaySamples: 100,
                eqChainMeasuredDelaySamples: 100,
                isActive: true
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 0), 0)
        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 1), 150)

        // Simulate Option 3 de-escalation on path 0 (decreased latency)
        pathLatencies[0] = PathLatencyInfo(
            totalLatencySamples: 100,  // Decreased from 350
            crossoverFilterDelaySamples: 50,
            eqChainMeasuredDelaySamples: 50,  // Option 3 removed
            isActive: true
        )

        engine.updatePathLatencies(pathLatencies)

        // After de-escalation, path 1 becomes the max latency path
        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 0), 100)  // 200 - 100
        XCTAssertEqual(engine.compensatingDelayForPath(channelIndex: 1), 0)
        XCTAssertEqual(engine.effectiveLatencyMs, 200.0 / sampleRate * 1000.0, accuracy: 0.01)
    }

    // MARK: - Audio Processing Tests

    func testDelayLineProcessing() {
        // Test that delay line actually delays audio
        let pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 100,
                crossoverFilterDelaySamples: 50,
                eqChainMeasuredDelaySamples: 50,
                isActive: true
            ),
            1: PathLatencyInfo(
                totalLatencySamples: 200,
                crossoverFilterDelaySamples: 100,
                eqChainMeasuredDelaySamples: 100,
                isActive: true
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        var output: [Float] = [0, 0, 0, 0, 0]

        // Process path 0 (should have 100 samples delay)
        engine.process(channelIndex: 0,
                      input: input,
                      output: &output,
                      frameCount: input.count)

        // With 100 samples delay and only 5 samples processed,
        // output should be zeros (delay buffer not filled yet)
        XCTAssertEqual(output, [0, 0, 0, 0, 0], "Output should be zeros initially due to delay")
    }

    func testReset() {
        let pathLatencies: [Int: PathLatencyInfo] = [
            0: PathLatencyInfo(
                totalLatencySamples: 100,
                crossoverFilterDelaySamples: 50,
                eqChainMeasuredDelaySamples: 50,
                isActive: true
            ),
            1: PathLatencyInfo(
                totalLatencySamples: 200,
                crossoverFilterDelaySamples: 100,
                eqChainMeasuredDelaySamples: 100,
                isActive: true
            )
        ]

        engine.updatePathLatencies(pathLatencies)

        // Process some audio to fill delay buffers
        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        var output: [Float] = [0, 0, 0, 0, 0]
        engine.process(channelIndex: 0, input: input, output: &output, frameCount: input.count)

        // Reset should clear delay buffers
        engine.reset()

        // After reset, processing should behave as if starting fresh
        engine.process(channelIndex: 0, input: input, output: &output, frameCount: input.count)
        XCTAssertEqual(output, [0, 0, 0, 0, 0], "Output should be zeros after reset (buffer cleared)")
    }
}
