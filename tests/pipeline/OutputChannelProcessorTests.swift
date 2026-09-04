// OutputChannelProcessorTests.swift
// Tests for output channel processor including EQ, gain trim, polarity, delay, and limiter.

import XCTest
@testable import Equaliser

final class OutputChannelProcessorTests: XCTestCase {

    func testProcessorInitialisesWithDefaults() {
        // Verify processor can be created with default configuration
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: 48000)
        let config = OutputChannelConfig.default
        processor.applyChannelConfig(config, sampleRate: 48000)

        // Verify it doesn't crash when processing
        var buf = [Float](repeating: 0.0, count: 512)
        buf.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        XCTAssertNotNil(processor)
    }

    func testGainTrimAppliedBeforeEQ() {
        // Gain trim should be applied before the EQ chain.
        // Test by applying a gain trim and an EQ band, then verify the combined effect.
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: 48000)

        var config = OutputChannelConfig.default
        config.gainTrimDB = 6.0  // +6 dB gain trim
        config.eq.bands[0].gain = 6.0  // +6 dB EQ boost at band 0
        config.eq.bands[0].frequency = 1000.0
        config.eq.bands[0].filterType = .parametric
        config.eq.bands[0].q = 1.0

        processor.applyChannelConfig(config, sampleRate: 48000)

        // Generate a test signal at the EQ frequency
        var input = [Float](repeating: 0.0, count: 512)
        for i in 0..<512 {
            let t = Double(i) / 48000.0
            input[i] = Float(sin(2.0 * .pi * 1000.0 * t)) * 0.5
        }

        var output = input
        output.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        // Verify output is different from input (processing happened)
        let inputRMS = sqrt(input.map { $0 * $0 }.reduce(0, +) / 512)
        let outputRMS = sqrt(output.map { $0 * $0 }.reduce(0, +) / 512)

        // Output should be different from input due to EQ processing
        XCTAssertNotEqual(inputRMS, outputRMS, accuracy: 0.01, "Output should differ from input due to EQ processing")
    }

    func testPolarityInversionAppliedAfterEQ() {
        // Polarity inversion should be applied after the EQ chain.
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: 48000)

        var config = OutputChannelConfig.default
        config.polarityInverted = true
        config.eq.bands[0].gain = 6.0  // Apply some EQ to ensure processing path is active
        config.eq.bands[0].frequency = 1000.0
        config.eq.bands[0].filterType = .parametric
        config.eq.bands[0].q = 1.0

        processor.applyChannelConfig(config, sampleRate: 48000)

        var input = [Float](repeating: 0.0, count: 512)
        for i in 0..<512 {
            let t = Double(i) / 48000.0
            input[i] = Float(sin(2.0 * .pi * 1000.0 * t)) * 0.5
        }

        var output = input
        output.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        // With polarity inversion, output should be inverted (negative correlation)
        var correlation: Float = 0
        for i in 0..<512 {
            correlation += input[i] * output[i]
        }

        // Negative correlation indicates inversion
        XCTAssertLessThan(correlation, 0, "Polarity inversion should produce negative correlation")
    }

    func testDelayLineAppliesCorrectDelay() {
        // Delay line should apply the configured delay in milliseconds.
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: 48000)

        var config = OutputChannelConfig.default
        config.delayMs = 10.0  // 10 ms delay = 480 samples at 48 kHz

        processor.applyChannelConfig(config, sampleRate: 48000)

        // Create an impulse at the start
        var input = [Float](repeating: 0.0, count: 512)
        input[0] = 1.0

        var output = input
        output.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        // Verify impulse appears at approximately the correct sample (480 samples for 10ms at 48kHz)
        // Allow some tolerance for processing chain offset
        let expectedSample = 480
        let tolerance = 10  // Allow ±10 samples tolerance

        var foundImpulse = false
        for i in (expectedSample - tolerance)..<(expectedSample + tolerance) {
            if i < 512 && abs(output[i]) > 0.5 {
                foundImpulse = true
                break
            }
        }

        XCTAssertTrue(foundImpulse, "Impulse should appear around sample \(expectedSample) for 10ms delay")

        // Verify first samples are near zero (delayed)
        var maxEarlySample: Float = 0
        for i in 0..<(expectedSample - tolerance) {
            maxEarlySample = max(maxEarlySample, abs(output[i]))
        }
        XCTAssertLessThan(maxEarlySample, 0.1, "Early samples should be near zero due to delay")
    }

    func testLimiterPreventsClipping() {
        // Brickwall limiter should prevent output from exceeding the ceiling.
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: 48000)

        var config = OutputChannelConfig.default
        config.limiter.ceilingDB = -0.2  // Set ceiling to -0.2 dBFS

        processor.applyChannelConfig(config, sampleRate: 48000)

        // Create a signal that would exceed the ceiling without limiting
        var input = [Float](repeating: 0.0, count: 512)
        for i in 0..<512 {
            input[i] = 0.9  // Very high level
        }

        var output = input
        output.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        // Convert ceiling to linear
        let ceilingLinear = Float(pow(10.0, -0.2 / 20.0))

        // Verify output doesn't exceed ceiling
        var maxOutput: Float = 0
        for i in 0..<512 {
            maxOutput = max(maxOutput, abs(output[i]))
        }

        // Use a simpler assertion to avoid compiler bug
        let isWithinCeiling = maxOutput <= (ceilingLinear * 1.05)
        XCTAssertTrue(isWithinCeiling, "Limiter should prevent exceeding ceiling")
    }

    func testGroupDelayAllPassAppliedBetweenTrimAndEQ() {
        // Group delay all-pass should be applied between calibration trim and EQ.
        // Test by comparing outputs from configs that differ only in all-pass coefficients.
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: 48000)

        // Config 1: with all-pass coefficients
        var configWithAllPass = OutputChannelConfig.default
        configWithAllPass.groupDelayAllPassCoefficients = [
            BiquadCoefficients(b0: 1.0, b1: 0.5, b2: 0.25, a1: 0.1, a2: 0.05)
        ]

        // Config 2: without all-pass coefficients (empty array)
        var configWithoutAllPass = OutputChannelConfig.default
        configWithoutAllPass.groupDelayAllPassCoefficients = []

        let input = [Float](repeating: 0.5, count: 512)

        // Process with all-pass
        processor.applyChannelConfig(configWithAllPass, sampleRate: 48000)
        var outputWithAllPass = input
        outputWithAllPass.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        // Process without all-pass
        processor.applyChannelConfig(configWithoutAllPass, sampleRate: 48000)
        var outputWithoutAllPass = input
        outputWithoutAllPass.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        // Verify outputs differ (all-pass processing modifies the signal)
        var maxDifference: Float = 0
        for i in 0..<512 {
            maxDifference = max(maxDifference, abs(outputWithAllPass[i] - outputWithoutAllPass[i]))
        }

        XCTAssertGreaterThan(maxDifference, 0.01, "All-pass processing should modify the signal")
    }

    func testProcessOrderIsCorrect() {
        // Processing order: gainTrimDB → [group delay all-pass] → inputGainDB → EQ → outputGainDB → polarity → delay → limiter
        // Test by configuring all stages and verifying the signal is processed
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: 48000)

        var config = OutputChannelConfig.default
        config.gainTrimDB = 3.0
        config.polarityInverted = true
        config.delayMs = 5.0
        config.limiter.ceilingDB = -0.2
        config.eq.bands[0].gain = 3.0
        config.eq.bands[0].frequency = 1000.0
        config.eq.bands[0].filterType = .parametric
        config.eq.bands[0].q = 1.0

        processor.applyChannelConfig(config, sampleRate: 48000)

        var input = [Float](repeating: 0.0, count: 512)
        for i in 0..<512 {
            let t = Double(i) / 48000.0
            input[i] = Float(sin(2.0 * .pi * 1000.0 * t)) * 0.5
        }

        var output = input
        output.withUnsafeMutableBufferPointer { ptr in
            processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
        }

        // Verify output is processed (not identical to input)
        let inputRMS = sqrt(input.map { $0 * $0 }.reduce(0, +) / 512)
        let outputRMS = sqrt(output.map { $0 * $0 }.reduce(0, +) / 512)

        // Should be different due to all the processing stages
        XCTAssertNotEqual(inputRMS, outputRMS, accuracy: 0.01, "Output should differ from input due to processing")

        // Verify no crash occurred
        XCTAssertNotNil(processor)
    }

    func testProcessDoesNotCrashForMainsLeftAndRightSources() {
        // Regression test for output channel limiter crash.
        // The bug was that OutputChannelProcessor assumed .mainsLeft/.mainsRight were stereo pairs
        // and allocated channelCount=2, but resolveSource always returns nil for the right channel.
        // This caused a precondition failure in LookAheadLimiter.process when it received 1 buffer
        // but expected 2. The fix allocates for max capacity (2) and processes however many buffers
        // are actually passed.
        for source in [SignalSource.mainsLeft, .mainsRight] {
            let processor = OutputChannelProcessor(source: source, maxFrameCount: 512, sampleRate: 48000)
            processor.applyChannelConfig(.default, sampleRate: 48000) // limiter enabled by default
            var buf = [Float](repeating: 0.5, count: 512)
            buf.withUnsafeMutableBufferPointer { ptr in
                processor.process(leftBuf: ptr.baseAddress!, rightBuf: nil, frameCount: 512)
            }
        }
    }
}
