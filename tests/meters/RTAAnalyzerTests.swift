import XCTest
@testable import Equaliser

@MainActor
final class RTAAnalyzerTests: XCTestCase {

    func testFullScaleSineNear0dBFS() {
        let analyzer = AdvancedDualSpectrumAnalyzer(fftSize: 2048)
        let sr: Float = 48_000
        let freq: Float = 1000
        var samples = [Float](repeating: 0, count: 2048)
        for i in 0..<2048 {
            samples[i] = sin(2 * Float.pi * freq * Float(i) / sr)
        }
        analyzer.updateSmearedSpectrums(
            inputSamples: samples, inputGainDb: 0,
            outputSamples: samples, outputGainDb: 0,
            sampleRate: sr
        )
        let band1k = analyzer.inputBands[17].currentValue
        XCTAssertGreaterThan(band1k, -6, "1 kHz tone should be within a few dB of 0 dBFS")
        XCTAssertLessThan(band1k, 3, "1 kHz tone should not read far above 0 dBFS")
    }

    func testSilenceNearFloor() {
        let analyzer = AdvancedDualSpectrumAnalyzer(fftSize: 2048)
        let silence = [Float](repeating: 0, count: 2048)
        analyzer.updateSmearedSpectrums(
            inputSamples: silence, inputGainDb: 0,
            outputSamples: silence, outputGainDb: 0,
            sampleRate: 48_000
        )
        let maxBand = analyzer.inputBands.map(\.currentValue).max() ?? 0
        XCTAssertLessThan(maxBand, -50, "Silence should sit near the -80 dBFS floor")
    }

    func testNormaliseDbMapsSilenceAndClip() {
        let analyzer = AdvancedDualSpectrumAnalyzer()
        XCTAssertEqual(analyzer.normaliseDb(-80), 0, accuracy: 0.001)
        XCTAssertEqual(analyzer.normaliseDb(0), 1, accuracy: 0.001)
    }

    func testBallisticsConstantsAt60Hz() {
        let analyzer = AdvancedDualSpectrumAnalyzer()
        // Verify peak hold is 60 frames (1.0s @ 60Hz)
        XCTAssertEqual(analyzer.peakHoldMax, 60)
        // Verify falling alpha is ≈0.847 (derived from 0.1s time constant @ 60Hz)
        XCTAssertEqual(analyzer.fallingAlpha, 0.847, accuracy: 0.01)
        // Verify peak decay is ≈0.959 (derived from 0.4s time constant @ 60Hz)
        XCTAssertEqual(analyzer.peakDecay, 0.959, accuracy: 0.01)
    }
}
