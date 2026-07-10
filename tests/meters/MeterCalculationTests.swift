import XCTest
@testable import Equaliser

final class MeterCalculationTests: XCTestCase {
    // MARK: - Normalized Position Tests

    func testNormalizedPosition_boundaries() {
        // 0 dB (max) → 1.0
        XCTAssertEqual(MeterConstants.normalizedPosition(for: 0), 1.0, accuracy: 0.001)
        // -60 dB (min) → 0.0
        XCTAssertEqual(MeterConstants.normalizedPosition(for: -60), 0.0, accuracy: 0.001)
    }

    func testNormalizedPosition_outOfRange() {
        XCTAssertEqual(MeterConstants.normalizedPosition(for: 6), 1.0, accuracy: 0.001)
        XCTAssertEqual(MeterConstants.normalizedPosition(for: 20), 1.0, accuracy: 0.001)
        // Below -60 dB should clamp to 0.0
        XCTAssertEqual(MeterConstants.normalizedPosition(for: -70), 0.0, accuracy: 0.001)
        XCTAssertEqual(MeterConstants.normalizedPosition(for: -100), 0.0, accuracy: 0.001)
    }

    func testNormalizedPosition_midRange() {
        // Linear in dB now (not gamma-corrected) — -30 dB is the exact midpoint of -60...0,
        // so it should land at ~0.5, not just "somewhere between 0.2 and 0.8".
        let midPosition = MeterConstants.normalizedPosition(for: -30)
        XCTAssertEqual(midPosition, 0.5, accuracy: 0.01)

        let minus6Position = MeterConstants.normalizedPosition(for: -6)
        XCTAssertGreaterThan(minus6Position, midPosition)

        let minus45Position = MeterConstants.normalizedPosition(for: -45)
        XCTAssertLessThan(minus45Position, midPosition)
    }

    func testNormalizedPosition_monotonicallyIncreasing() {
        // Update the sample points to span the real range, -60...0
        let dbValues: [Float] = [-60, -48, -36, -30, -24, -18, -12, -6, 0]
        var previousPosition: Float = -1
        for db in dbValues {
            let position = MeterConstants.normalizedPosition(for: db)
            XCTAssertGreaterThan(position, previousPosition, "Position should increase as dB increases")
            previousPosition = position
        }
    }

    // MARK: - Meter Constants Tests

    func testMeterRange_values() {
        // Current MeterConstants.meterRange is -60...0, not -36...0
        XCTAssertEqual(MeterConstants.meterRange.lowerBound, -60)
        XCTAssertEqual(MeterConstants.meterRange.upperBound, 0)
    }

    // DELETE testGamma_value entirely — MeterConstants.gamma no longer exists.
    // normalizedPosition's doc comment now explicitly states:
    // "Linear in dB (not gamma-corrected) — matches conventional PPM meter behavior."

    func testStandardTickValues() {
        // Current standardTickValues has 10 entries with finer near-top granularity
        let expectedTicks: [Float] = [0, -3, -6, -12, -18, -24, -30, -36, -48, -60]
        XCTAssertEqual(MeterConstants.standardTickValues, expectedTicks)
    }

    // MARK: - Peak Detection Tests

    func testPeakDetection_maxAbsValue() {
        // Test that peak detection finds maximum absolute value
        let samples: [Float] = [-0.5, 0.3, -0.8, 0.2, 0.6]
        let peak = samples.map { abs($0) }.max() ?? 0

        XCTAssertEqual(peak, 0.8, accuracy: 0.001)
    }

    func testPeakDetection_negativeOnly() {
        let samples: [Float] = [-0.2, -0.5, -0.3, -0.1]
        let peak = samples.map { abs($0) }.max() ?? 0

        XCTAssertEqual(peak, 0.5, accuracy: 0.001)
    }

    func testPeakDetection_silence() {
        let samples: [Float] = [0, 0, 0, 0]
        let peak = samples.map { abs($0) }.max() ?? 0

        XCTAssertEqual(peak, 0)
    }

    // MARK: - RMS Calculation Tests

    /// Standard RMS formula: sqrt(sum(x^2) / n)
    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    func testRmsCalculation_dcSignal() {
        // For a constant (DC) signal, RMS equals the amplitude
        let amplitude: Float = 0.5
        let samples = [Float](repeating: amplitude, count: 100)
        let rms = calculateRMS(samples)

        XCTAssertEqual(rms, amplitude, accuracy: 0.001)
    }

    func testRmsCalculation_sineWave() {
        // For a sine wave, RMS = amplitude / sqrt(2)
        let amplitude: Float = 1.0
        let sampleCount = 1000
        var samples = [Float]()

        for i in 0..<sampleCount {
            let phase = Float(i) / Float(sampleCount) * 2 * .pi
            samples.append(amplitude * sin(phase))
        }

        let rms = calculateRMS(samples)
        let expectedRMS = amplitude / sqrt(2)

        XCTAssertEqual(rms, expectedRMS, accuracy: 0.01)
    }

    func testRmsCalculation_silence() {
        let samples: [Float] = [0, 0, 0, 0, 0]
        let rms = calculateRMS(samples)

        XCTAssertEqual(rms, 0)
    }

    func testRmsCalculation_squareWave() {
        // For a square wave oscillating between +A and -A, RMS equals |A|
        let amplitude: Float = 0.8
        var samples = [Float]()

        for i in 0..<100 {
            samples.append(i % 2 == 0 ? amplitude : -amplitude)
        }

        let rms = calculateRMS(samples)

        XCTAssertEqual(rms, amplitude, accuracy: 0.001)
    }

    // MARK: - MeterMath Tests

    func testMeterMath_linearToDB_silence() {
        // Very low values should return silence floor
        XCTAssertEqual(MeterMath.linearToDB(0), MeterConstants.silenceDB, accuracy: 0.001)
        XCTAssertEqual(MeterMath.linearToDB(1e-8), MeterConstants.silenceDB, accuracy: 0.001)
    }

    func testMeterMath_linearToDB_referenceValues() {
        // Unity gain
        XCTAssertEqual(MeterMath.linearToDB(1.0), 0, accuracy: 0.001)

        // Half amplitude
        XCTAssertEqual(MeterMath.linearToDB(0.5), -6.02, accuracy: 0.02)

        // Double amplitude
        XCTAssertEqual(MeterMath.linearToDB(2.0), 6.02, accuracy: 0.02)
    }

    func testMeterMath_dbToLinear_referenceValues() {
        // Unity gain
        XCTAssertEqual(MeterMath.dbToLinear(0), 1.0, accuracy: 0.001)

        // -6 dB
        XCTAssertEqual(MeterMath.dbToLinear(-6), 0.5, accuracy: 0.01)

        // +6 dB
        XCTAssertEqual(MeterMath.dbToLinear(6), 2.0, accuracy: 0.01)
    }

    func testMeterMath_calculatePeak_silence() {
        let buffer: [Float] = [0, 0, 0, 0, 0]
        let peak = MeterMath.calculatePeak(buffer: buffer, frameCount: buffer.count)
        XCTAssertEqual(peak, 0, accuracy: 0.001)
    }

    func testMeterMath_calculatePeak_positive() {
        let buffer: [Float] = [0.1, 0.5, 0.3, 0.2]
        let peak = MeterMath.calculatePeak(buffer: buffer, frameCount: buffer.count)
        XCTAssertEqual(peak, 0.5, accuracy: 0.001)
    }

    func testMeterMath_calculatePeak_negative() {
        let buffer: [Float] = [-0.1, -0.5, -0.3, -0.2]
        let peak = MeterMath.calculatePeak(buffer: buffer, frameCount: buffer.count)
        XCTAssertEqual(peak, 0.5, accuracy: 0.001)
    }

    func testMeterMath_calculatePeak_mixed() {
        let buffer: [Float] = [-0.3, 0.7, -0.5, 0.2]
        let peak = MeterMath.calculatePeak(buffer: buffer, frameCount: buffer.count)
        XCTAssertEqual(peak, 0.7, accuracy: 0.001)
    }

    func testMeterMath_calculateRMS_silence() {
        let buffer: [Float] = [0, 0, 0, 0, 0]
        let rms = MeterMath.calculateRMS(buffer: buffer, frameCount: buffer.count)
        XCTAssertEqual(rms, 0, accuracy: 0.001)
    }

    func testMeterMath_calculateRMS_dcSignal() {
        let buffer: [Float] = [Float](repeating: 0.5, count: 100)
        let rms = MeterMath.calculateRMS(buffer: buffer, frameCount: buffer.count)
        XCTAssertEqual(rms, 0.5, accuracy: 0.001)
    }

    func testMeterMath_smoothMeter_attack() {
        // Attack smoothing (rising value)
        let result = MeterMath.smoothMeter(
            current: 0.0,
            target: 1.0,
            attackSmoothing: 1.0,  // Instant attack
            releaseSmoothing: 0.5
        )
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testMeterMath_smoothMeter_release() {
        // Release smoothing (falling value)
        let result = MeterMath.smoothMeter(
            current: 1.0,
            target: 0.0,
            attackSmoothing: 1.0,
            releaseSmoothing: 0.5  // Half-way toward target per call
        )
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    func testMeterMath_smoothMeter_bounds() {
        // Should clamp to 0-1 range
        let lowerBound = MeterMath.smoothMeter(
            current: 0.0,
            target: -1.0,
            attackSmoothing: 1.0,
            releaseSmoothing: 1.0
        )
        XCTAssertEqual(lowerBound, 0, accuracy: 0.001)

        let upperBound = MeterMath.smoothMeter(
            current: 1.0,
            target: 2.0,
            attackSmoothing: 1.0,
            releaseSmoothing: 1.0
        )
        XCTAssertEqual(upperBound, 1, accuracy: 0.001)
    }

    // MARK: - Delegation Tests

    func testMeterMath_delegatesToAudioMath() {
        // MeterMath should delegate to AudioMath with same results
        let dbValues: [Float] = [-60.0, -36.0, -20.0, 0.0, 6.0, 20.0]
        for db in dbValues {
            XCTAssertEqual(
                MeterMath.dbToLinear(db),
                AudioMath.dbToLinear(db),
                "MeterMath.dbToLinear should delegate to AudioMath for \(db) dB"
            )
        }

        let linearValues: [Float] = [0.001, 0.1, 0.5, 1.0, 2.0, 10.0]
        for linear in linearValues {
            XCTAssertEqual(
                MeterMath.linearToDB(linear),
                AudioMath.linearToDB(linear),
                "MeterMath.linearToDB should delegate to AudioMath for \(linear)"
            )
        }
    }
}
