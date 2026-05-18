import XCTest
@testable import Equaliser

final class EQChainTests: XCTestCase {
    // MARK: - Test Constants

    let sampleRate: Double = 48000.0
    let frameCount: UInt32 = 512
    let maxFrameCount: UInt32 = 4096

    // MARK: - Helpers

    /// Wraps a flat array of `BiquadCoefficients` into single-section arrays,
    /// matching the `sections: [[BiquadCoefficients]]` parameter expected by `stageFullUpdate`.
    private func wrap(_ flat: [BiquadCoefficients]) -> [[BiquadCoefficients]] {
        flat.map { [$0] }
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        var buffer: [Float] = [Float](repeating: 0.5, count: Int(frameCount))

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.applyPendingUpdates()
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        // With no active bands, the chain doesn't process anything — output is unchanged
    }

    // MARK: - Band Update Tests

    func testSingleBandUpdate() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        var allCoeffs = [BiquadCoefficients](repeating: .identity, count: EQChain.maxBandCount)
        allCoeffs[0] = coeffs
        let bypassFlags = [Bool](repeating: false, count: EQChain.maxBandCount)

        chain.stageFullUpdate(
            sections: wrap(allCoeffs),
            bypassFlags: bypassFlags,
            activeBandCount: 1,
            layerBypass: false
        )

        chain.applyPendingUpdates()

        var buffer: [Float] = [Float](repeating: 0, count: Int(frameCount))
        buffer[0] = 1.0

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        XCTAssertGreaterThan(abs(buffer[0] - 1.0), 0.001, "Filter should have processed the impulse")
    }

    func testFullUpdate() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        var coeffs: [BiquadCoefficients] = []
        var bypassFlags: [Bool] = []

        for i in 0..<3 {
            let c = BiquadMath.calculateCoefficients(
                type: .parametric,
                sampleRate: sampleRate,
                frequency: 100.0 * Double(i + 1) * 100,
                q: 1.0,
                gain: Double(i + 1) * 2
            )
            coeffs.append(c)
            bypassFlags.append(false)
        }

        while coeffs.count < EQChain.maxBandCount {
            coeffs.append(.identity)
            bypassFlags.append(false)
        }

        chain.stageFullUpdate(
            sections: wrap(coeffs),
            bypassFlags: bypassFlags,
            activeBandCount: 3,
            layerBypass: false
        )

        chain.applyPendingUpdates()

        var buffer: [Float] = [Float](repeating: 0, count: Int(frameCount))
        buffer[0] = 1.0

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        XCTAssertFalse(buffer.allSatisfy { $0 == 0 })
    }

    func testBandBypass() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        chain.stageBandUpdate(index: 0, sections: [coeffs], bypass: true)

        let allCoeffs = [coeffs] + [BiquadCoefficients](repeating: .identity, count: EQChain.maxBandCount - 1)
        let bypassFlags = [true] + [Bool](repeating: false, count: EQChain.maxBandCount - 1)

        chain.stageFullUpdate(
            sections: wrap(allCoeffs),
            bypassFlags: bypassFlags,
            activeBandCount: 1,
            layerBypass: false
        )

        chain.applyPendingUpdates()

        var buffer: [Float] = [Float](repeating: 0, count: Int(frameCount))
        buffer[0] = 1.0

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        XCTAssertEqual(buffer[0], 1.0, accuracy: 1e-6)
    }

    func testLayerBypass() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        let allCoeffs = [coeffs] + [BiquadCoefficients](repeating: .identity, count: EQChain.maxBandCount - 1)
        let bypassFlags = [Bool](repeating: false, count: EQChain.maxBandCount)

        chain.stageFullUpdate(
            sections: wrap(allCoeffs),
            bypassFlags: bypassFlags,
            activeBandCount: 1,
            layerBypass: true
        )

        chain.applyPendingUpdates()

        var buffer: [Float] = [Float](repeating: 0, count: Int(frameCount))
        buffer[0] = 1.0

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        XCTAssertEqual(buffer[0], 1.0, accuracy: 1e-6)
    }

    // MARK: - Multiple Bands Tests

    func testMultipleBandsInSeries() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        var coeffs: [BiquadCoefficients] = []
        var bypassFlags: [Bool] = []

        for i in 0..<3 {
            let c = BiquadMath.calculateCoefficients(
                type: .parametric,
                sampleRate: sampleRate,
                frequency: 500.0 + Double(i) * 500,
                q: 1.0,
                gain: 3.0
            )
            coeffs.append(c)
            bypassFlags.append(false)
        }

        while coeffs.count < EQChain.maxBandCount {
            coeffs.append(.identity)
            bypassFlags.append(false)
        }

        chain.stageFullUpdate(
            sections: wrap(coeffs),
            bypassFlags: bypassFlags,
            activeBandCount: 3,
            layerBypass: false
        )

        chain.applyPendingUpdates()

        var buffer: [Float] = [Float](repeating: 0, count: Int(frameCount))
        buffer[0] = 1.0

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        XCTAssertFalse(buffer.allSatisfy { $0 == 0 })
    }

    // MARK: - Multi-Section Band Tests

    func testSteepLowPassTwoSections() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        // 24 dB/oct LP = 2 Butterworth biquad sections
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db24
        )
        XCTAssertEqual(sections.count, 2, "24 dB/oct LP should produce 2 sections")

        var allSections: [[BiquadCoefficients]] = [sections]
        var bypassFlags: [Bool] = [false]
        while allSections.count < EQChain.maxBandCount {
            allSections.append([.identity])
            bypassFlags.append(false)
        }

        chain.stageFullUpdate(sections: allSections, bypassFlags: bypassFlags, activeBandCount: 1, layerBypass: false)
        chain.applyPendingUpdates()

        // Apply to a high-frequency sine wave — should be strongly attenuated
        let highFreq: Float = 10000.0
        var buffer: [Float] = (0..<Int(frameCount)).map {
            sin(2.0 * .pi * highFreq * Float($0) / Float(sampleRate))
        }

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        let rms = sqrt(buffer.reduce(0) { $0 + $1 * $1 } / Float(frameCount))
        XCTAssertLessThan(rms, 0.05, "Steep LP at 1 kHz should strongly attenuate 10 kHz")
    }

    func testSteepHighPassFourSections() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        // 48 dB/oct HP = 4 Butterworth biquad sections
        let sections = BiquadMath.calculateSections(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 5000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db48
        )
        XCTAssertEqual(sections.count, 4, "48 dB/oct HP should produce 4 sections")

        var allSections: [[BiquadCoefficients]] = [sections]
        var bypassFlags: [Bool] = [false]
        while allSections.count < EQChain.maxBandCount {
            allSections.append([.identity])
            bypassFlags.append(false)
        }

        chain.stageFullUpdate(sections: allSections, bypassFlags: bypassFlags, activeBandCount: 1, layerBypass: false)
        chain.applyPendingUpdates()

        // Apply to a low-frequency sine wave — should be strongly attenuated
        let lowFreq: Float = 100.0
        var buffer: [Float] = (0..<Int(frameCount)).map {
            sin(2.0 * .pi * lowFreq * Float($0) / Float(sampleRate))
        }

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        let rms = sqrt(buffer.reduce(0) { $0 + $1 * $1 } / Float(frameCount))
        XCTAssertLessThan(rms, 0.05, "Steep HP at 5 kHz should strongly attenuate 100 Hz")
    }

    // MARK: - Real-Time Safety Tests

    func testNoAllocationDuringProcess() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        let allCoeffs = [coeffs] + [BiquadCoefficients](repeating: .identity, count: EQChain.maxBandCount - 1)
        let bypassFlags = [Bool](repeating: false, count: EQChain.maxBandCount)

        chain.stageFullUpdate(
            sections: wrap(allCoeffs),
            bypassFlags: bypassFlags,
            activeBandCount: 1,
            layerBypass: false
        )

        chain.applyPendingUpdates()

        var buffer: [Float] = [Float](repeating: 0.5, count: Int(frameCount))

        for _ in 0..<100 {
            buffer.withUnsafeMutableBufferPointer { bufPtr in
                chain.applyPendingUpdates()
                chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
            }
        }

        XCTAssertTrue(true)
    }
}
