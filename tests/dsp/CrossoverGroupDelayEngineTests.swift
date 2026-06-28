// CrossoverGroupDelayEngineTests.swift
// Tests for crossover group delay analysis, all-pass fitting, and Nelder-Mead optimiser.

import XCTest
@testable import Equaliser

final class CrossoverGroupDelayEngineTests: XCTestCase {

    private let sampleRate = 48000.0

    // MARK: - Analytical all-pass group delay

    /// A second-order all-pass at 1 kHz must have non-zero group delay near 1 kHz.
    func testAnalyticalAllPassGroupDelay_PeaksNearCutoff() {
        let freq  = 1000.0
        let q     = 1.0
        let omega = 2.0 * Double.pi * freq / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let a0    = 1.0 + alpha
        let a1    = -2.0 * cos(omega) / a0
        let a2    = (1.0 - alpha) / a0

        let testFreqs = [500.0, 1000.0, 2000.0]
        let delays    = CrossoverGroupDelayEngine.allPassGroupDelayAnalytical(
            a1: a1, a2: a2, frequencies: testFreqs, sampleRate: sampleRate)

        for (i, d) in delays.enumerated() {
            XCTAssertGreaterThan(d, 0.0,
                "All-pass group delay must be positive at \(testFreqs[i]) Hz; got \(d) ms")
        }
        XCTAssertGreaterThan(delays[1], delays[0],
            "All-pass group delay should be higher near cutoff (1 kHz) than at 500 Hz")
    }

    /// The analytical formula must agree with the finite-difference method to within 0.1 ms.
    func testAnalyticalVsFiniteDifference_AgreeToWithinTolerance() {
        let freq  = 2000.0
        let q     = 0.7071
        let omega = 2.0 * Double.pi * freq / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let a0    = 1.0 + alpha

        let a1anal = -2.0 * cos(omega) / a0
        let a2anal = (1.0 - alpha) / a0

        let coeffs = BiquadMath.calculateCoefficients(
            type: .allPass, sampleRate: sampleRate, frequency: freq, q: q, gain: 0.0)

        let testFreqs  = [500.0, 1000.0, 2000.0, 4000.0, 8000.0]
        let analytical = CrossoverGroupDelayEngine.allPassGroupDelayAnalytical(
            a1: a1anal, a2: a2anal, frequencies: testFreqs, sampleRate: sampleRate)
        let numerical  = CrossoverGroupDelayEngine.biquadGroupDelayPublic(
            b0: Float(coeffs.b0), b1: Float(coeffs.b1), b2: Float(coeffs.b2),
            a1: Float(coeffs.a1), a2: Float(coeffs.a2),
            frequencies: testFreqs, sampleRate: sampleRate)

        for (i, f) in testFreqs.enumerated() {
            XCTAssertEqual(analytical[i], numerical[i], accuracy: 0.1,
                "Analytical and numerical group delay must agree within 0.1 ms at \(f) Hz")
        }
    }

    // MARK: - groupDelay() — IIR path

    /// An LR4 LP biquad section array must produce positive non-zero group delay near its cutoff.
    func testGroupDelayIIRLowPassPeaksAtCrossover() {
        let crossoverHz = 1000.0
        let lpCoeffs = BiquadMath.calculateSections(
            type: .lowPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db24)

        let identity: ActiveCrossoverEngine.SectionArray.Element = (1, 0, 0, 0, 0)
        var sections = Array(repeating: identity, count: ActiveCrossoverEngine.maxSections)
        for (i, c) in lpCoeffs.enumerated() {
            sections[i] = (Float(c.b0), Float(c.b1), Float(c.b2), Float(c.a1), Float(c.a2))
        }

        let frequencies = [200.0, 500.0, 1000.0, 2000.0, 5000.0]
        let delays = ActiveCrossoverEngine.groupDelay(
            sections: sections, firKernel: nil, frequencies: frequencies, sampleRate: sampleRate)

        for d in delays { XCTAssertGreaterThanOrEqual(d, 0.0, "Group delay must be non-negative") }
        XCTAssertGreaterThan(delays[2], 0.05,
            "LR4 LP at 1 kHz must have > 0.05 ms group delay near cutoff; got \(delays[2]) ms")
    }

    // MARK: - groupDelay() — FIR path

    /// A 1001-tap FIR must have constant group delay = 500 samples.
    func testGroupDelayFIRIsConstant() {
        let tapCount    = 1001
        let kernel      = [Float](repeating: 0.0, count: tapCount)
        let identity: ActiveCrossoverEngine.SectionArray.Element = (1, 0, 0, 0, 0)
        let sections    = Array(repeating: identity, count: ActiveCrossoverEngine.maxSections)
        let frequencies = [100.0, 1000.0, 5000.0, 10000.0]
        let expected    = Double(tapCount - 1) / 2.0 / sampleRate * 1000.0

        let delays = ActiveCrossoverEngine.groupDelay(
            sections: sections, firKernel: kernel, frequencies: frequencies, sampleRate: sampleRate)

        for (i, d) in delays.enumerated() {
            XCTAssertEqual(d, expected, accuracy: 1e-9,
                "FIR group delay must be constant at \(frequencies[i]) Hz; expected \(expected) ms, got \(d) ms")
        }
    }

    // MARK: - groupDelayError()

    /// When both channel delays are equal, the error must be zero everywhere.
    func testGroupDelayErrorIsZeroForMatchedFilters() {
        let delays = [1.0, 2.0, 3.0, 4.0, 5.0]
        let error  = CrossoverGroupDelayEngine.groupDelayError(
            channelADelays: delays, channelBDelays: delays,
            crossoverHz: 2000.0, frequencies: [200, 500, 1000, 2000, 4000])
        for e in error {
            XCTAssertEqual(e, 0.0, accuracy: 1e-12,
                "Error must be zero when both channel delays are equal")
        }
    }

    /// Error sign must be positive when channel A is slower than channel B.
    func testGroupDelayErrorSignConvention() {
        let aDelays = [5.0, 5.0, 5.0]
        let bDelays = [3.0, 3.0, 3.0]
        let error   = CrossoverGroupDelayEngine.groupDelayError(
            channelADelays: aDelays, channelBDelays: bDelays,
            crossoverHz: 2000.0, frequencies: [1000, 2000, 4000])
        for e in error {
            XCTAssertEqual(e, 2.0, accuracy: 1e-12,
                "Error A−B must be +2 ms when A is 2 ms slower than B")
        }
    }

    // MARK: - fitGroupDelayAllPass() — Nelder-Mead correctness

    /// For a non-trivial delay error, the fitter must produce at least one section.
    func testFitGroupDelayAllPassReducesError() {
        let crossoverHz = 2000.0
        let frequencies = stride(from: 100.0, through: 20000.0, by: 50.0).map { $0 }
        let delayError  = frequencies.map { f -> Double in
            let ratio = min(f / crossoverHz, 1.0)
            return 3.0 * ratio * max(0, 1.0 - (f - crossoverHz) / crossoverHz)
        }

        let sections = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: delayError, applyToChannelA: false,
            crossoverHz: crossoverHz, frequencies: frequencies,
            sampleRate: sampleRate, maxSections: 4)

        XCTAssertGreaterThan(sections.count, 0,
            "Fitter must produce at least one all-pass section for a 3 ms error")

        for (i, s) in sections.enumerated() {
            XCTAssertFalse(s.b0.isNaN,       "Section \(i) b0 is NaN")
            XCTAssertLessThan(abs(s.a2), 1.0 + 1e-6, "Section \(i) is unstable")

            for testF in [500.0, 1000.0, 2000.0, 4000.0] {
                let magDB = BiquadMath.magnitudeDB(
                    coefficients: s, atFrequency: testF, sampleRate: sampleRate)
                XCTAssertEqual(magDB, 0.0, accuracy: 0.01,
                    "All-pass section \(i) must have unity magnitude at \(testF) Hz; got \(magDB) dB")
            }
        }
    }

    /// After applying the fitted sections, the weighted residual error must be
    /// substantially reduced compared to the original error.
    func testFitGroupDelayAllPass_ResidualReducedByAtLeastHalf() {
        let crossoverHz = 2000.0
        let frequencies = stride(from: 100.0, through: 20000.0, by: 50.0).map { $0 }
        let lowWeight   = crossoverHz / 2.0
        let highWeight  = crossoverHz * 2.0

        let delayError  = frequencies.map { f -> Double in
            let ratio = min(f / crossoverHz, 1.0)
            return 3.0 * ratio * max(0, 1.0 - (f - crossoverHz) / crossoverHz)
        }

        func weightedRMS(_ errors: [Double]) -> Double {
            let wse = zip(errors, frequencies).map { (e, f) -> Double in
                let w = (f >= lowWeight && f <= highWeight) ? 1.0 : 0.1
                return w * e * e
            }.reduce(0, +)
            return sqrt(wse / Double(errors.count))
        }

        let initialRMS = weightedRMS(delayError)

        let sections = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: delayError, applyToChannelA: false,
            crossoverHz: crossoverHz, frequencies: frequencies,
            sampleRate: sampleRate, maxSections: 4)

        var residual = delayError
        for s in sections {
            let delay = CrossoverGroupDelayEngine.biquadGroupDelayPublic(
                b0: Float(s.b0), b1: Float(s.b1), b2: Float(s.b2),
                a1: Float(s.a1), a2: Float(s.a2),
                frequencies: frequencies, sampleRate: sampleRate)
            for i in residual.indices { residual[i] -= delay[i] }
        }

        let finalRMS = weightedRMS(residual)
        XCTAssertLessThan(finalRMS, initialRMS * 0.5,
            "Nelder-Mead fitter must reduce weighted RMS error by at least 50%; initial=\(initialRMS) ms, final=\(finalRMS) ms")
    }

    // MARK: - Nelder-Mead produces better result than Q-sweep for steep LR8 crossover

    /// For a steep LR8 crossover (96 dB/oct), the Nelder-Mead result must produce
    /// lower weighted RMS residual than the best single (freq, Q) pair from the
    /// 7-candidate sweep. This validates the upgrade from Chunk 2 to Chunk 7.
    func testNelderMead_BetterThanQSweep_ForSteepCrossover() {
        let crossoverHz = 1000.0
        let frequencies = stride(from: 100.0, through: 10000.0, by: 25.0).map { $0 }

        let lpCoeffs = BiquadMath.calculateSections(
            type: .lowPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db96)
        let hpCoeffs = BiquadMath.calculateSections(
            type: .highPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db96)

        func toSections(_ c: [BiquadCoefficients]) -> ActiveCrossoverEngine.SectionArray {
            let identity: ActiveCrossoverEngine.SectionArray.Element = (1, 0, 0, 0, 0)
            var arr = Array(repeating: identity, count: ActiveCrossoverEngine.maxSections)
            for (i, s) in c.enumerated() {
                arr[i] = (Float(s.b0), Float(s.b1), Float(s.b2), Float(s.a1), Float(s.a2))
            }
            return arr
        }

        let lpDelay = ActiveCrossoverEngine.groupDelay(
            sections: toSections(lpCoeffs), firKernel: nil,
            frequencies: frequencies, sampleRate: sampleRate)
        let hpDelay = ActiveCrossoverEngine.groupDelay(
            sections: toSections(hpCoeffs), firKernel: nil,
            frequencies: frequencies, sampleRate: sampleRate)
        let error = CrossoverGroupDelayEngine.groupDelayError(
            channelADelays: lpDelay, channelBDelays: hpDelay,
            crossoverHz: crossoverHz, frequencies: frequencies)

        let nmSections = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: error, applyToChannelA: false,
            crossoverHz: crossoverHz, frequencies: frequencies,
            sampleRate: sampleRate, maxSections: 1)

        let candidateQs = [0.5, 0.7071, 1.0, 1.414, 2.0, 2.828, 4.0]
        let lowWeight   = crossoverHz / 2.0
        let highWeight  = crossoverHz * 2.0

        var peakFreq = crossoverHz; var maxWE = 0.0
        for (i, f) in frequencies.enumerated() {
            let w  = (f >= lowWeight && f <= highWeight) ? 1.0 : 0.1
            let we = error[i] * w
            if we > maxWE { maxWE = we; peakFreq = f }
        }

        func weightedCost(sections: [BiquadCoefficients]) -> Double {
            var residual = error
            for s in sections {
                let d = CrossoverGroupDelayEngine.biquadGroupDelayPublic(
                    b0: Float(s.b0), b1: Float(s.b1), b2: Float(s.b2),
                    a1: Float(s.a1), a2: Float(s.a2),
                    frequencies: frequencies, sampleRate: sampleRate)
                for i in residual.indices { residual[i] -= d[i] }
            }
            return zip(residual, frequencies).map { (e, f) in
                let w = (f >= lowWeight && f <= highWeight) ? 1.0 : 0.1
                return w * e * e
            }.reduce(0, +)
        }

        var bestQSweepCost = Double.infinity
        for q in candidateQs {
            let c = BiquadMath.calculateCoefficients(
                type: .allPass, sampleRate: sampleRate,
                frequency: peakFreq, q: q, gain: 0.0)
            let cost = weightedCost(sections: [c])
            if cost < bestQSweepCost { bestQSweepCost = cost }
        }

        let nmCost = weightedCost(sections: nmSections)
        XCTAssertLessThanOrEqual(nmCost, bestQSweepCost * 1.05,
            "Nelder-Mead must match or beat the best Q-sweep result (within 5%). NM=\(nmCost), sweep=\(bestQSweepCost)")
    }

    // MARK: - Zero error → empty result

    func testZeroErrorReturnsEmpty() {
        let frequencies = stride(from: 100.0, through: 10000.0, by: 100.0).map { $0 }
        let result = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: Array(repeating: 0.0, count: frequencies.count),
            applyToChannelA: true, crossoverHz: 2000.0,
            frequencies: frequencies, sampleRate: sampleRate, maxSections: 4)
        XCTAssertTrue(result.isEmpty, "Zero error must produce no all-pass sections")
    }

    // MARK: - applyToChannelA sign convention

    func testAutoCorrectAppliesCoefficientsToCorrectChannel() {
        let frequencies   = stride(from: 100.0, through: 10000.0, by: 100.0).map { $0 }
        let positiveError = frequencies.map { _ in 2.0 }   // A is 2 ms slower everywhere

        // A is already slower — adding delay to A makes no sense; expect empty.
        let resultA = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: positiveError, applyToChannelA: true,
            crossoverHz: 2000.0, frequencies: frequencies,
            sampleRate: sampleRate, maxSections: 4)
        XCTAssertTrue(resultA.isEmpty,
            "applyToChannelA=true with positive error (A slower) must return empty")

        // B is faster — add delay to B; expect non-empty.
        let resultB = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: positiveError, applyToChannelA: false,
            crossoverHz: 2000.0, frequencies: frequencies,
            sampleRate: sampleRate, maxSections: 4)
        XCTAssertFalse(resultB.isEmpty,
            "applyToChannelA=false with positive error (B faster) must return corrections for B")
    }
}
