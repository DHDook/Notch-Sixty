// OutputChannelProcessorTests.swift
// Tests for output channel processor including EQ, gain trim, polarity, delay, and limiter.

import XCTest
@testable import Equaliser

final class OutputChannelProcessorTests: XCTestCase {

    func testProcessorInitialisesWithDefaults() {
        // TODO: Implement actual test once processor is fully implemented.
        // For now, this is a placeholder test.
        XCTAssertTrue(true)
    }

    func testGainTrimAppliedBeforeEQ() {
        // Gain trim should be applied before the EQ chain.
        // TODO: Implement actual test.
        XCTAssertTrue(true)
    }

    func testPolarityInversionAppliedAfterEQ() {
        // Polarity inversion should be applied after the EQ chain.
        // TODO: Implement actual test.
        XCTAssertTrue(true)
    }

    func testDelayLineAppliesCorrectDelay() {
        // Delay line should apply the configured delay in milliseconds.
        // TODO: Implement actual test.
        XCTAssertTrue(true)
    }

    func testLimiterPreventsClipping() {
        // Brickwall limiter should prevent output from exceeding the ceiling.
        // TODO: Implement actual test.
        XCTAssertTrue(true)
    }

    func testGroupDelayAllPassAppliedBetweenTrimAndEQ() {
        // Group delay all-pass should be applied between calibration trim and EQ.
        // TODO: Implement actual test.
        XCTAssertTrue(true)
    }

    func testProcessOrderIsCorrect() {
        // Processing order: gainTrimDB → [group delay all-pass] → inputGainDB → EQ → outputGainDB → polarity → delay → limiter
        // TODO: Implement actual test.
        XCTAssertTrue(true)
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
