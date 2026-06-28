// BassManagementCrossoverTests.swift
// Tests for BassManagementCrossover coefficient accuracy at all sample rates.

import XCTest
@testable import Equaliser

final class BassManagementCrossoverTests: XCTestCase {

    // MARK: - Standard rates: decoupled and non-decoupled produce identical output

    /// At 48 kHz, decoupling is a no-op. Coefficients must be bit-identical.
    func testCoefficients_48kHz_DecoupledEqualsNonDecoupled() {
        let coupled = BassManagementCrossover(
            crossoverHz: 80.0, slope: .lr4, sampleRate: 48000,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: false)
        let decoupled = BassManagementCrossover(
            crossoverHz: 80.0, slope: .lr4, sampleRate: 48000,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: true)

        for i in 0..<coupled.sectionCount {
            XCTAssertEqual(coupled.lowPassSections[i].b0,  decoupled.lowPassSections[i].b0,
                "b0 must be identical at 48 kHz (decoupling is a no-op)")
            XCTAssertEqual(coupled.highPassSections[i].b0, decoupled.highPassSections[i].b0,
                "HP b0 must be identical at 48 kHz")
        }
    }

    /// At 96 kHz (exactly at threshold), decoupling should not engage.
    func testCoefficients_96kHz_DecoupledEqualsNonDecoupled() {
        let coupled = BassManagementCrossover(
            crossoverHz: 80.0, slope: .lr4, sampleRate: 96000,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: false)
        let decoupled = BassManagementCrossover(
            crossoverHz: 80.0, slope: .lr4, sampleRate: 96000,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: true)

        for i in 0..<coupled.sectionCount {
            XCTAssertEqual(coupled.lowPassSections[i].b0, decoupled.lowPassSections[i].b0,
                "b0 must be identical at 96 kHz (threshold is > 96 kHz)")
        }
    }

    // MARK: - High rates: decoupled coefficients are not pole-crowded

    /// At 384 kHz without decoupling, b0 of the LP biquad is in the 10⁻⁷ range —
    /// near the Float precision floor. With decoupling, b0 is in the 10⁻³ range
    /// (designed at 48 kHz reference), confirming no pole crowding.
    func testCoefficients_384kHz_DecouplingPreventsPoleCrowding() {
        let crossoverHz: Float = 80.0
        let sampleRate: Double = 384000

        let coupled = BassManagementCrossover(
            crossoverHz: crossoverHz, slope: .lr4, sampleRate: sampleRate,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: false)
        let decoupled = BassManagementCrossover(
            crossoverHz: crossoverHz, slope: .lr4, sampleRate: sampleRate,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: true)

        // Non-decoupled: b0 should be extremely small (pole-crowding territory)
        let coupledB0 = coupled.lowPassSections[0].b0
        XCTAssertLessThan(Double(coupledB0), 1e-5,
            "Without decoupling at 384 kHz, LP b0 should be < 1e-5 (pole crowding confirmed)")

        // Decoupled: b0 should be in a numerically stable range (> 1e-4)
        let decoupledB0 = decoupled.lowPassSections[0].b0
        XCTAssertGreaterThan(Double(decoupledB0), 1e-4,
            "With decoupling at 384 kHz, LP b0 should be > 1e-4 (no pole crowding)")
    }

    // MARK: - Crossover frequency accuracy with decoupling

    /// With decoupling enabled at 384 kHz, the LP filter's −6 dB point must land
    /// within acceptable tolerance of the target crossover frequency when evaluated
    /// at the actual sample rate. This validates that prewarpFrequency correctly
    /// compensates for the bilinear transform's frequency compression.
    func testCrossoverFrequencyAccuracy_384kHz_Decoupled_WithinOnHz() {
        let targetHz: Float = 80.0
        let sampleRate: Double = 384000

        let crossover = BassManagementCrossover(
            crossoverHz: targetHz, slope: .lr4, sampleRate: sampleRate,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: true)

        // Evaluate the cascaded LP magnitude at the target frequency.
        // |H_cascade(ω)|² = ∏ |H_i(ω)|² per section
        let omega = 2.0 * Double.pi * Double(targetHz) / sampleRate

        var mag2 = 1.0
        for section in crossover.lowPassSections {
            let b0 = Double(section.b0)
            let b1 = Double(section.b1)
            let b2 = Double(section.b2)
            let a1 = Double(section.na1)
            let a2 = Double(section.na2)

            let cosW  = cos(omega)
            let cos2W = cos(2 * omega)
            let num = b0*b0 + b1*b1 + b2*b2 + 2*b0*b1*cosW + 2*b0*b2*cos2W + 2*b1*b2*cosW
            let den = 1.0  + a1*a1 + a2*a2 + 2*a1*cosW   + 2*a2*cos2W   + 2*a1*a2*cosW
            mag2 *= num / den
        }

        // For LR4 LP, the −6 dB point is at Fc (two cascaded −3 dB Butterworth sections).
        let magDB = 10.0 * log10(mag2)

        XCTAssertEqual(magDB, -6.0, accuracy: 0.5,
            "LR4 LP cascade at target frequency should be −6 dB ±0.5 dB at \(sampleRate) Hz; got \(magDB) dB")
    }

    /// Same frequency accuracy test at 192 kHz.
    func testCrossoverFrequencyAccuracy_192kHz_Decoupled() {
        let targetHz: Float = 80.0
        let sampleRate: Double = 192000

        let crossover = BassManagementCrossover(
            crossoverHz: targetHz, slope: .lr4, sampleRate: sampleRate,
            crossoverType: .linkwitzRiley, coefficientDecouplingEnabled: true)

        let omega = 2.0 * Double.pi * Double(targetHz) / sampleRate
        var mag2 = 1.0
        for section in crossover.lowPassSections {
            let b0 = Double(section.b0), b1 = Double(section.b1), b2 = Double(section.b2)
            let a1 = Double(section.na1), a2 = Double(section.na2)
            let cosW = cos(omega), cos2W = cos(2 * omega)
            let num = b0*b0 + b1*b1 + b2*b2 + 2*b0*b1*cosW + 2*b0*b2*cos2W + 2*b1*b2*cosW
            let den = 1.0  + a1*a1 + a2*a2 + 2*a1*cosW   + 2*a2*cos2W   + 2*a1*a2*cosW
            mag2 *= num / den
        }
        let magDB = 10.0 * log10(mag2)
        XCTAssertEqual(magDB, -6.0, accuracy: 0.5,
            "LR4 LP at 192 kHz should be −6 dB ±0.5 dB at target frequency; got \(magDB) dB")
    }

    // MARK: - All crossover types and slopes at 384 kHz

    /// All crossover types and slopes should produce stable (non-NaN, non-Inf) coefficients
    /// with decoupling enabled at 384 kHz.
    func testAllCrossoverTypes_384kHz_Decoupled_AreStable() {
        let types: [CrossoverType] = [.linkwitzRiley, .butterworth, .bessel]
        let slopes: [BassCrossoverSlope] = [.lr2, .lr4, .lr8]

        for type in types {
            for slope in slopes {
                let c = BassManagementCrossover(
                    crossoverHz: 80.0, slope: slope, sampleRate: 384000,
                    crossoverType: type, coefficientDecouplingEnabled: true)

                for (i, sec) in c.lowPassSections.enumerated() {
                    XCTAssertFalse(sec.b0.isNaN,      "\(type)/\(slope) LP section \(i) b0 is NaN at 384 kHz")
                    XCTAssertFalse(sec.b0.isInfinite, "\(type)/\(slope) LP section \(i) b0 is Inf at 384 kHz")
                    XCTAssertFalse(sec.na1.isNaN,     "\(type)/\(slope) LP section \(i) a1 is NaN at 384 kHz")
                    XCTAssertLessThan(abs(sec.na2), 1.0 + 1e-6,
                        "\(type)/\(slope) LP section \(i) is unstable at 384 kHz")
                }
                for (i, sec) in c.highPassSections.enumerated() {
                    XCTAssertFalse(sec.b0.isNaN,      "\(type)/\(slope) HP section \(i) b0 is NaN at 384 kHz")
                    XCTAssertFalse(sec.b0.isInfinite, "\(type)/\(slope) HP section \(i) b0 is Inf at 384 kHz")
                    XCTAssertLessThan(abs(sec.na2), 1.0 + 1e-6,
                        "\(type)/\(slope) HP section \(i) is unstable at 384 kHz")
                }
            }
        }
    }

    // MARK: - DynamicsProcessor: sample rate change triggers re-staging

    /// When the sample rate changes while crossover parameters stay constant,
    /// applyConfig() must still re-stage crossover coefficients. This tests
    /// the lastBassCrossoverSampleRate guard added in Part C.
    func testDynamicsProcessor_SampleRateChange_TriggersCrossoverRestage() {
        let processor = DynamicsProcessor(
            maxFrameCount: 512, channelCount: 2, sampleRate: 48000)

        var config = DynamicsConfig.default
        config.advanced.bassManagement.enabled = true
        config.advanced.bassManagement.crossoverHz = 80.0
        config.advanced.coefficientDecouplingEnabled = true

        // Initial apply at 48 kHz
        processor.applyConfig(config, sampleRate: 48000)
        let coeffs48k = processor.pendingBassCrossover.lowPassSections[0].b0

        // Apply the same config but at 384 kHz — must re-stage
        processor.applyConfig(config, sampleRate: 384000)
        let coeffs384k = processor.pendingBassCrossover.lowPassSections[0].b0

        // Coefficients must differ (384 kHz decoupled ≠ 48 kHz raw)
        XCTAssertNotEqual(coeffs48k, coeffs384k,
            "Changing sample rate from 48 kHz to 384 kHz must produce different crossover coefficients")
    }
}
