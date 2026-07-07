import XCTest
@testable import Equaliser

@MainActor
final class RTAAnalyzerTests: XCTestCase {

    func testFullScaleSineNear0dBFS() {
        let analyzer = AdvancedDualSpectrumAnalyzer()
        let sr: Float = 48_000
        let freq: Float = 1000
        var samples = [Float](repeating: 0, count: 262144) // Use largest lane size
        for i in 0..<262144 {
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
        let analyzer = AdvancedDualSpectrumAnalyzer()
        let silence = [Float](repeating: 0, count: 262144) // Use largest lane size
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

    func testBandMappingAcrossAllSupportedSampleRatesUpTo384kHz() {
        // Regression test: 1/3-octave bands narrower than one FFT bin (common at the
        // low end, and increasingly common at higher sample rates since bin width
        // grows with sample rate for a fixed FFT size) used to produce an invalid
        // loBinIndex > hiBinIndex range in computeBandRanges, which trapped when
        // mapBinsToBands constructed loBinIndex...hiBinIndex directly. The app is
        // designed to support every sample rate up to 384kHz, so every tier needs
        // to be exercised here, not just the common 44.1/48kHz ones.
        let analyzer = AdvancedDualSpectrumAnalyzer()
        let supportedSampleRates: [Float] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
        let silence = [Float](repeating: 0, count: 262144) // Use largest lane size

        for sr in supportedSampleRates {
            analyzer.updateSmearedSpectrums(
                inputSamples: silence, inputGainDb: 0,
                outputSamples: silence, outputGainDb: 0,
                sampleRate: sr
            )
            // Should not crash (the regression itself), and every band should still
            // produce a finite, in-range value even when it had to fall back to a
            // single nearest bin because the band was narrower than one bin.
            for band in analyzer.inputBands {
                XCTAssertTrue(band.currentValue.isFinite, "sampleRate \(sr): band value should be finite")
                XCTAssertGreaterThanOrEqual(band.currentValue, analyzer.minDb, "sampleRate \(sr): band value should not be below the floor")
                XCTAssertLessThanOrEqual(band.currentValue, analyzer.maxDb, "sampleRate \(sr): band value should not exceed 0 dBFS")
            }
        }
    }

    func testMultiLaneBandRoutingAcrossAllSupportedSampleRatesUpTo384kHz() {
        let analyzer = AdvancedDualSpectrumAnalyzer()
        let supportedSampleRates: [Float] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

        for sr in supportedSampleRates {
            analyzer.assumedSampleRate = sr
            // Use white noise as full-spectrum test signal
            var signal = [Float](repeating: 0, count: 262144)
            for i in 0..<262144 {
                signal[i] = Float.random(in: -0.5...0.5)
            }
            analyzer.updateSmearedSpectrums(
                inputSamples: signal, inputGainDb: 0,
                outputSamples: signal, outputGainDb: 0,
                sampleRate: sr
            )
            for band in analyzer.inputBands {
                XCTAssertTrue(band.currentValue.isFinite, "sampleRate \(sr): band value should be finite")
                XCTAssertGreaterThan(band.currentValue, analyzer.minDb, "sampleRate \(sr): white noise should register above the floor on every band")
            }
        }
    }
}
