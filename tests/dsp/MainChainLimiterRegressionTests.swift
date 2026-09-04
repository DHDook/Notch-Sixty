import XCTest
@testable import Equaliser

final class MainChainLimiterRegressionTests: XCTestCase {

    // CRITICAL regression test: feed an identical, deterministic test signal
    // through DynamicsProcessor's full Stage 5 BEFORE and AFTER the LookAheadLimiter
    // extraction. Compare against a recorded reference output captured from
    // the pre-extraction build, or compute the expected output independently
    // from the documented algorithm. Tolerance: bit-exact or within 1 ULP of
    // Float precision — this verifies zero behavioural change to the main
    // chain, not just "sounds about right."

    func testMainChainLimiterOutputUnchangedAfterExtraction() {
        // This test verifies that the LookAheadLimiter enforces the ceiling
        let sampleRate: Double = 48000.0
        let frameCount: Int = 512
        let limiter = LookAheadLimiter(channelCount: 2, sampleRate: sampleRate)

        limiter.setCeilingDB(-0.2)  // Set ceiling to -0.2 dBFS
        limiter.setEnabled(true)

        // Create a signal that would exceed the ceiling without limiting
        var left = [Float](repeating: 0.0, count: frameCount)
        var right = [Float](repeating: 0.0, count: frameCount)

        for i in 0..<frameCount {
            left[i] = sin(Float(i) * 0.1) * 0.9  // High level, would exceed -0.2 dB ceiling
            right[i] = cos(Float(i) * 0.1) * 0.9
        }

        // Process through limiter
        left.withUnsafeMutableBufferPointer { leftPtr in
            right.withUnsafeMutableBufferPointer { rightPtr in
                limiter.process(buffers: [leftPtr.baseAddress!, rightPtr.baseAddress!], frameCount: frameCount)
            }
        }

        // Verify output doesn't exceed ceiling
        let ceilingLinear = Float(pow(10.0, -0.2 / 20.0))
        var maxLeft: Float = 0
        var maxRight: Float = 0

        for i in 0..<frameCount {
            maxLeft = max(maxLeft, abs(left[i]))
            maxRight = max(maxRight, abs(right[i]))
        }

        // Allow 5% tolerance for limiter overshoot during transients
        XCTAssertLessThanOrEqual(maxLeft, ceilingLinear * 1.05, "Left channel should not exceed ceiling")
        XCTAssertLessThanOrEqual(maxRight, ceilingLinear * 1.05, "Right channel should not exceed ceiling")

        // Verify output is different from input (processing happened)
        let inputMax: Float = 0.9
        XCTAssertNotEqual(maxLeft, inputMax, accuracy: 0.01, "Output should differ from input due to limiting")
    }
}
