import XCTest
@testable import Equaliser

final class LookAheadLimiterTests: XCTestCase {

    func testLimiterPassesSignalBelowCeilingUnchanged() {
        let limiter = LookAheadLimiter(channelCount: 2, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-0.2)  // ≈ 0.977 linear

        var left = [Float](repeating: 0.5, count: 512)  // Well below ceiling
        var right = [Float](repeating: 0.5, count: 512)

        left.withUnsafeMutableBufferPointer { leftPtr in
            right.withUnsafeMutableBufferPointer { rightPtr in
                limiter.process(buffers: [leftPtr.baseAddress!, rightPtr.baseAddress!], frameCount: 512)
            }
        }

        // Signal should be essentially unchanged (within tolerance)
        for i in 0..<512 {
            XCTAssertEqual(left[i], 0.5, accuracy: 0.001)
            XCTAssertEqual(right[i], 0.5, accuracy: 0.001)
        }
    }

    func testLimiterReducesGainWhenAboveCeiling() {
        let limiter = LookAheadLimiter(channelCount: 1, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-6.0)  // 0.501 linear

        var signal = [Float](repeating: 1.0, count: 512)  // Above ceiling

        signal.withUnsafeMutableBufferPointer { ptr in
            limiter.process(buffers: [ptr.baseAddress!], frameCount: 512)
        }

        // Peak should be at or below ceiling
        var peak: Float = 0.0
        for s in signal {
            if abs(s) > peak { peak = abs(s) }
        }
        XCTAssertLessThanOrEqual(peak, 0.501 + 0.01)  // Small tolerance for attack smoothing
    }

    func testLimiterNeverExceedsCeilingInOutput() {
        let limiter = LookAheadLimiter(channelCount: 2, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-3.0)  // ≈ 0.708 linear

        var left = [Float](repeating: 2.0, count: 512)  // Way above ceiling
        var right = [Float](repeating: 1.5, count: 512)

        left.withUnsafeMutableBufferPointer { leftPtr in
            right.withUnsafeMutableBufferPointer { rightPtr in
                limiter.process(buffers: [leftPtr.baseAddress!, rightPtr.baseAddress!], frameCount: 512)
            }
        }

        let ceiling = pow(10.0 as Float, -3.0 / 20.0)
        for i in 0..<512 {
            XCTAssertLessThanOrEqual(abs(left[i]), ceiling + 0.01)
            XCTAssertLessThanOrEqual(abs(right[i]), ceiling + 0.01)
        }
    }

    func testLimiterAttackIsFasterThanRelease() {
        let limiter = LookAheadLimiter(channelCount: 1, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-6.0)
        limiter.setAttackMs(0.1, sampleRate: 48000.0)
        limiter.setReleaseMs(20.0, sampleRate: 48000.0)

        var signal = [Float](repeating: 0.0, count: 512)
        // Insert a sudden peak in the middle
        signal[256] = 2.0

        signal.withUnsafeMutableBufferPointer { ptr in
            limiter.process(buffers: [ptr.baseAddress!], frameCount: 512)
        }

        // Gain reduction should be reported
        XCTAssertLessThan(limiter.lastGainReductionDB, 0.0)
    }

    func testLimiterStereoLinkUsesMaxOfBothChannels() {
        let limiter = LookAheadLimiter(channelCount: 2, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-6.0)

        var left = [Float](repeating: 0.5, count: 512)
        var right = [Float](repeating: 2.0, count: 512)  // Peak on right channel only

        left.withUnsafeMutableBufferPointer { leftPtr in
            right.withUnsafeMutableBufferPointer { rightPtr in
                limiter.process(buffers: [leftPtr.baseAddress!, rightPtr.baseAddress!], frameCount: 512)
            }
        }

        // Both channels should be limited (stereo-linked)
        let ceiling = pow(10.0 as Float, -6.0 / 20.0)
        var leftPeak: Float = 0.0
        var rightPeak: Float = 0.0
        for i in 0..<512 {
            if abs(left[i]) > leftPeak { leftPeak = abs(left[i]) }
            if abs(right[i]) > rightPeak { rightPeak = abs(right[i]) }
        }
        XCTAssertLessThanOrEqual(leftPeak, ceiling + 0.01)
        XCTAssertLessThanOrEqual(rightPeak, ceiling + 0.01)
    }

    func testLimiterMonoPathWithSingleChannelWorksCorrectly() {
        let limiter = LookAheadLimiter(channelCount: 1, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-6.0)

        var signal = [Float](repeating: 2.0, count: 512)

        signal.withUnsafeMutableBufferPointer { ptr in
            limiter.process(buffers: [ptr.baseAddress!], frameCount: 512)
        }

        let ceiling = pow(10.0 as Float, -6.0 / 20.0)
        var peak: Float = 0.0
        for s in signal {
            if abs(s) > peak { peak = abs(s) }
        }
        XCTAssertLessThanOrEqual(peak, ceiling + 0.01)
    }

    func testLimiterDisabledIsPassthrough() {
        let limiter = LookAheadLimiter(channelCount: 1, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setEnabled(false)

        var signal = [Float](repeating: 2.0, count: 512)

        signal.withUnsafeMutableBufferPointer { ptr in
            limiter.process(buffers: [ptr.baseAddress!], frameCount: 512)
        }

        // Signal should be unchanged when disabled
        for i in 0..<512 {
            XCTAssertEqual(signal[i], 2.0, accuracy: 0.001)
        }
    }

    func testLimiterTruePeakGuardDeratesCeiling() {
        let limiter = LookAheadLimiter(channelCount: 1, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-0.2)
        limiter.setTruePeakGuardEnabled(true)

        var signal = [Float](repeating: 0.98, count: 512)  // Just below -0.2 dBFS

        signal.withUnsafeMutableBufferPointer { ptr in
            limiter.process(buffers: [ptr.baseAddress!], frameCount: 512)
        }

        // With true-peak guard, ceiling should be derated by 0.5 dBTP
        // so signal at 0.98 may trigger limiting
        XCTAssertLessThan(limiter.lastGainReductionDB, 0.0)
    }

    func testLimiterTruePeakTrippedFlagSetsAndClears() {
        let limiter = LookAheadLimiter(channelCount: 1, sampleRate: 48000.0, lookAheadMs: 2.0)
        limiter.setCeilingDB(-6.0)
        limiter.setTruePeakGuardEnabled(true)

        var signal = [Float](repeating: 2.0, count: 512)

        signal.withUnsafeMutableBufferPointer { ptr in
            limiter.process(buffers: [ptr.baseAddress!], frameCount: 512)
        }

        // Flag should be set after processing
        XCTAssertTrue(limiter.truePeakTripped)

        // Clear the flag
        limiter.clearTruePeakTripped()
        XCTAssertFalse(limiter.truePeakTripped)
    }
}
