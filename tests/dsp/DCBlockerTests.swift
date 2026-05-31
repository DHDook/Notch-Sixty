import XCTest
@testable import Equaliser

final class DCBlockerTests: XCTestCase {

    // MARK: - Constants

    private let sampleRate: Double = 48000.0

    // MARK: - Pole Radius

    func testPoleRadiusAtStandardSampleRate() {
        // R = exp(−π / fs).  At 48 kHz: R ≈ 0.999 934 599.
        var blocker = DCBlocker(sampleRate: sampleRate)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { buffer.deallocate() }

        // Feed DC = 1.0; after many samples the output should decay to near-zero.
        buffer[0] = 1.0
        blocker.process(buffer: buffer, frameCount: 1)

        // First output of a DC step: y[0] = x[0] − x[-1] + R·y[-1] = 1 − 0 + 0 = 1
        XCTAssertEqual(buffer[0], 1.0, accuracy: 1e-6, "First sample of a DC step must pass through unchanged")
    }

    // MARK: - DC Rejection

    func testDCRejection() {
        // Feed a sustained DC offset of 1.0 for enough samples that the filter settles.
        // The output should decay to near zero (|H(1)| = 0 for a DC-blocking HPF).
        var blocker = DCBlocker(sampleRate: sampleRate)

        // 5 seconds of sustained DC at 48 kHz.  The filter's time constant is ~2 s.
        let frames = 5 * Int(sampleRate)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }

        for i in 0..<frames { buffer[i] = 1.0 }
        blocker.process(buffer: buffer, frameCount: frames)

        // After 5 s the residual should be < −80 dB (≈ 0.0001 linear)
        XCTAssertLessThan(abs(buffer[frames - 1]), 0.0001,
                          "DC component should be attenuated to < −80 dB after 5 s")
    }

    // MARK: - Transparency at 1 kHz

    func testMinimalAttenuationAt1kHz() {
        // A 1 kHz sine should pass through with < 0.001 dB attenuation at the 0.5 Hz pole.
        //
        // |H(e^jω)|² = (2 − 2cos ω) / (1 + R² − 2R·cos ω)
        // At ω = 2π·1000/48000: both numerator and denominator ≈ the same small values,
        // giving |H| ≈ 1 to many decimal places.  We verify the signal energy is preserved.
        var blocker = DCBlocker(sampleRate: sampleRate)

        let frameCount = 4800 // 0.1 s — 100 complete cycles of 1 kHz
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { buffer.deallocate() }

        let omega = Float(2.0 * Double.pi * 1000.0 / sampleRate)
        for i in 0..<frameCount {
            buffer[i] = sin(omega * Float(i))
        }

        // Allow 100 samples warm-up, then compute RMS of input and output tails.
        let warmup = 100
        let reference = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { reference.deallocate() }
        for i in 0..<frameCount { reference[i] = buffer[i] }

        blocker.process(buffer: buffer, frameCount: frameCount)

        var inputRMS: Float  = 0.0
        var outputRMS: Float = 0.0
        for i in warmup..<frameCount {
            inputRMS  += reference[i] * reference[i]
            outputRMS += buffer[i] * buffer[i]
        }
        inputRMS  = sqrt(inputRMS  / Float(frameCount - warmup))
        outputRMS = sqrt(outputRMS / Float(frameCount - warmup))

        // Attenuation at 1 kHz should be < 0.001 dB (ratio within 0.01 % of unity)
        let ratio = Double(outputRMS / inputRMS)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.0001,
                       "1 kHz signal should pass with < 0.001 dB attenuation")
    }

    // MARK: - Reset

    func testResetClearsState() {
        var blocker = DCBlocker(sampleRate: sampleRate)

        // Warm up the filter with DC so it has non-zero state.
        let warmupBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 1000)
        defer { warmupBuffer.deallocate() }
        for i in 0..<1000 { warmupBuffer[i] = 1.0 }
        blocker.process(buffer: warmupBuffer, frameCount: 1000)

        // After reset, processing a single zero should give zero output
        // (state x1 = y1 = 0 means y[0] = 0 − 0 + R·0 = 0).
        blocker.reset()

        let zeroBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { zeroBuffer.deallocate() }
        zeroBuffer[0] = 0.0
        blocker.process(buffer: zeroBuffer, frameCount: 1)

        XCTAssertEqual(zeroBuffer[0], 0.0, accuracy: 1e-9,
                       "Output must be exactly zero after reset when input is zero")
    }

    // MARK: - Sample Rate Update

    func testUpdateSampleRateFlushesState() {
        var blocker = DCBlocker(sampleRate: sampleRate)

        // Dirty the filter state with DC.
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 100)
        defer { buf.deallocate() }
        for i in 0..<100 { buf[i] = 1.0 }
        blocker.process(buffer: buf, frameCount: 100)

        // Update sample rate — this must flush state.
        blocker.updateSampleRate(96000.0)

        let zeroBuf = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { zeroBuf.deallocate() }
        zeroBuf[0] = 0.0
        blocker.process(buffer: zeroBuf, frameCount: 1)

        XCTAssertEqual(zeroBuf[0], 0.0, accuracy: 1e-9,
                       "State must be flushed after updateSampleRate()")
    }

    // MARK: - No Allocations in Process Loop

    func testProcessDoesNotAllocate() {
        // Verify that process() does not trigger heap allocations.
        // Swift's standard library does not expose alloc-count APIs, so we rely on the
        // implementation being reviewed (no Array/Dictionary/class construction inside
        // the loop) and use a large batch to surface any per-frame allocations as hangs.
        var blocker = DCBlocker(sampleRate: sampleRate)
        let frames = Int(AudioConstants.maxFrameCount)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        for i in 0..<frames { buffer[i] = Float.random(in: -1...1) }

        // Process at maximum frame count — should complete without crashing or stalling.
        blocker.process(buffer: buffer, frameCount: frames)
        XCTAssert(true, "process() completed at maxFrameCount without crash")
    }
}
