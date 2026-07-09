// CrossoverGroupDelayEngine.swift
// Group delay analysis and all-pass fitting for crossover phase alignment.
// Computes group delay of crossover + EQ chains and fits all-pass filters
// to minimise group delay error at crossover points.

import Accelerate
import Foundation

enum CrossoverGroupDelayEngine {

    /// Computes the group delay of a complete output channel signal path.
    /// Combines the crossover filter group delay with the per-output EQ group delay.
    ///
    /// - Parameters:
    ///   - crossoverSections: The IIR section array for this channel's crossover filter
    ///     (e.g. activeLowerLP for a woofer channel). Nil for FIR crossover filters.
    ///   - crossoverFIRKernel: FIR kernel for this channel's crossover filter. Nil for IIR.
    ///   - eqBands: The per-output EQ band configurations active on this channel.
    ///   - frequencies: Frequency points at which to compute group delay (Hz).
    ///   - sampleRate: System sample rate.
    /// - Returns: Group delay in milliseconds at each frequency point.
    static func channelGroupDelay(
        crossoverSections: ActiveCrossoverEngine.SectionArray?,
        crossoverFIRKernel: [Float]?,
        eqBands: [EQBandConfiguration],
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        var groupDelay = Array(repeating: 0.0, count: frequencies.count)

        if let firKernel = crossoverFIRKernel {
            let firDelaySamples = Double(firKernel.count) / 2.0
            let firDelayMs = firDelaySamples / sampleRate * 1000.0
            for i in 0..<groupDelay.count { groupDelay[i] += firDelayMs }
        }

        if let sections = crossoverSections {
            for section in sections {
                // SectionArray stores negated a1/a2 (na1/na2) for DF2T recursion.
                // Phase calculation expects standard non-negated coefficients, so negate back.
                let sectionDelay = biquadGroupDelayPublic(
                    b0: section.b0, b1: section.b1, b2: section.b2,
                    a1: -section.na1, a2: -section.na2,
                    frequencies: frequencies, sampleRate: sampleRate
                )
                for i in 0..<groupDelay.count { groupDelay[i] += sectionDelay[i] }
            }
        }

        for band in eqBands {
            guard !band.bypass else { continue }
            let coeffs = BiquadMath.calculateCoefficients(
                type: band.filterType, sampleRate: sampleRate,
                frequency: Double(band.frequency), q: Double(band.q), gain: Double(band.gain)
            )
            let bandDelay = biquadGroupDelayPublic(
                b0: Float(coeffs.b0), b1: Float(coeffs.b1), b2: Float(coeffs.b2),
                a1: Float(coeffs.a1), a2: Float(coeffs.a2),
                frequencies: frequencies, sampleRate: sampleRate
            )
            for i in 0..<groupDelay.count { groupDelay[i] += bandDelay[i] }
        }

        return groupDelay
    }

    // MARK: - Private Helpers

    /// Computes group delay of a single biquad section at specified frequencies.
    /// Made internal (no access modifier) to allow use in tests via `biquadGroupDelayPublic`.
    static func biquadGroupDelayPublic(
        b0: Float, b1: Float, b2: Float,
        a1: Float, a2: Float,
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        let deltaF = 1.0
        var result: [Double] = []
        result.reserveCapacity(frequencies.count)

        for f in frequencies {
            let omega1 = 2.0 * Double.pi * (f - deltaF / 2.0) / sampleRate
            let omega2 = 2.0 * Double.pi * (f + deltaF / 2.0) / sampleRate

            let phase1 = biquadPhase(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, omega: omega1)
            let phase2 = biquadPhase(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, omega: omega2)

            var deltaPhase = phase2 - phase1
            while deltaPhase >  Double.pi { deltaPhase -= 2.0 * Double.pi }
            while deltaPhase < -Double.pi { deltaPhase += 2.0 * Double.pi }

            let delay = -deltaPhase / (2.0 * Double.pi * deltaF / sampleRate)
            result.append(delay * 1000.0)
        }
        return result
    }

    /// Computes phase response of a biquad at a given normalised frequency.
    private static func biquadPhase(
        b0: Float, b1: Float, b2: Float,
        a1: Float, a2: Float,
        omega: Double
    ) -> Double {
        let cosW  = cos(omega);  let sinW  = sin(omega)
        let cos2W = cos(2.0 * omega); let sin2W = sin(2.0 * omega)

        let numReal = Double(b0) + Double(b1) * cosW + Double(b2) * cos2W
        let numImag = Double(b1) * sinW + Double(b2) * sin2W
        let denReal = 1.0 + Double(a1) * cosW + Double(a2) * cos2W
        let denImag = Double(a1) * sinW + Double(a2) * sin2W

        let denMag = denReal * denReal + denImag * denImag
        guard denMag > 1e-30 else { return 0.0 }

        let real = (numReal * denReal + numImag * denImag) / denMag
        let imag = (numImag * denReal - numReal * denImag) / denMag
        return atan2(imag, real)
    }

    // MARK: - Analytical All-Pass Group Delay

    /// Computes the group delay of a second-order all-pass biquad analytically.
    ///
    /// Uses the closed-form expression for the RBJ all-pass:
    ///   GD(ω) = 2(1 − a₂²) / (1 + a₁² + a₂² + 2a₁(1+a₂)cosω + 2a₂cos2ω)
    ///
    /// This is ~3× faster than the numerical finite-difference method and produces
    /// a smooth cost function landscape for the Nelder-Mead optimiser.
    ///
    /// - Parameters:
    ///   - a1, a2: Normalised denominator coefficients (standard biquad form).
    ///   - frequencies: Frequencies in Hz at which to compute group delay.
    ///   - sampleRate: Sample rate in Hz.
    /// - Returns: Group delay in milliseconds at each frequency.
    static func allPassGroupDelayAnalytical(
        a1: Double,
        a2: Double,
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        let a2sq     = a2 * a2
        let a1sq     = a1 * a1
        let num      = 2.0 * (1.0 - a2sq)
        let a1_1pa2  = a1 * (1.0 + a2)

        return frequencies.map { f in
            let omega = 2.0 * Double.pi * f / sampleRate
            let cosW  = cos(omega)
            let cos2W = cos(2.0 * omega)
            let den   = 1.0 + a1sq + a2sq + 2.0 * a1_1pa2 * cosW + 2.0 * a2 * cos2W
            guard abs(den) > 1e-12 else { return 0.0 }
            return (num / den) / sampleRate * 1000.0   // samples → ms
        }
    }

    // MARK: - Nelder-Mead Simplex Optimiser (2D)

    /// Nelder-Mead simplex minimisation for a two-parameter cost function.
    ///
    /// Finds (x, y) that minimises `costFunction(x, y)` starting from `initialX`, `initialY`.
    /// Bounds [xMin, xMax] × [yMin, yMax] are enforced by clamping after each step.
    private static func nelderMead2D(
        initialX: Double,
        initialY: Double,
        xMin: Double, xMax: Double,
        yMin: Double, yMax: Double,
        initialStepX: Double,
        initialStepY: Double,
        maxIterations: Int = 150,
        tolerance: Double = 1e-4,
        costFunction: (Double, Double) -> Double
    ) -> (x: Double, y: Double) {

        let alpha = 1.0; let gamma = 2.0; let rho = 0.5; let sigma = 0.5

        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

        typealias Point = (x: Double, y: Double, cost: Double)
        func makePoint(_ x: Double, _ y: Double) -> Point {
            let cx = clamp(x, xMin, xMax); let cy = clamp(y, yMin, yMax)
            return (cx, cy, costFunction(cx, cy))
        }

        var simplex: [Point] = [
            makePoint(initialX,               initialY),
            makePoint(initialX + initialStepX, initialY),
            makePoint(initialX,               initialY + initialStepY)
        ]

        for _ in 0..<maxIterations {
            simplex.sort { $0.cost < $1.cost }
            let best  = simplex[0]; let worst = simplex[2]; let mid = simplex[1]

            let dx = max(abs(simplex[1].x - best.x), abs(simplex[2].x - best.x))
            let dy = max(abs(simplex[1].y - best.y), abs(simplex[2].y - best.y))
            if dx < tolerance && dy < tolerance { break }

            let cx = (best.x + mid.x) / 2.0; let cy = (best.y + mid.y) / 2.0

            let reflected = makePoint(cx + alpha * (cx - worst.x), cy + alpha * (cy - worst.y))

            if reflected.cost < best.cost {
                let expanded = makePoint(cx + gamma * (reflected.x - cx),
                                         cy + gamma * (reflected.y - cy))
                simplex[2] = expanded.cost < reflected.cost ? expanded : reflected
            } else if reflected.cost < mid.cost {
                simplex[2] = reflected
            } else {
                let better = reflected.cost < worst.cost ? reflected : worst
                let contracted = makePoint(cx + rho * (better.x - cx),
                                           cy + rho * (better.y - cy))
                if contracted.cost < better.cost {
                    simplex[2] = contracted
                } else {
                    simplex[1] = makePoint(best.x + sigma * (mid.x   - best.x),
                                           best.y + sigma * (mid.y   - best.y))
                    simplex[2] = makePoint(best.x + sigma * (worst.x - best.x),
                                           best.y + sigma * (worst.y - best.y))
                }
            }
        }

        simplex.sort { $0.cost < $1.cost }
        return (simplex[0].x, simplex[0].y)
    }

    // MARK: - groupDelayError

    /// Computes the group delay error between two output channels at the crossover point.
    ///
    /// Returns the per-frequency difference (channelA − channelB) in milliseconds.
    /// Positive values mean channel A arrives later (has more group delay) than channel B.
    ///
    /// - Parameters:
    ///   - channelADelays: Group delay of the lower-frequency channel (e.g. woofer), in ms.
    ///   - channelBDelays: Group delay of the higher-frequency channel (e.g. tweeter), in ms.
    ///   - crossoverHz: Retained for caller documentation; not used in computation.
    ///   - frequencies: The frequency grid used to compute both delay arrays.
    /// - Returns: Group delay difference (A − B) in ms at each frequency point.
    static func groupDelayError(
        channelADelays: [Double],
        channelBDelays: [Double],
        crossoverHz: Double,
        frequencies: [Double]
    ) -> [Double] {
        return zip(channelADelays, channelBDelays).map { $0 - $1 }
    }

    // MARK: - fitGroupDelayAllPass (Nelder-Mead)

    /// Fits an all-pass biquad chain to minimise group delay error at a crossover point
    /// using Nelder-Mead joint optimisation over (frequency, Q) per section.
    ///
    /// - Parameters:
    ///   - delayErrorMs: From groupDelayError — positive means channel A needs more delay.
    ///   - applyToChannelA: True if the all-pass should be applied to channel A.
    ///   - crossoverHz: Crossover frequency for weighting the fit.
    ///   - frequencies: Frequency points of delayErrorMs.
    ///   - sampleRate: System sample rate.
    ///   - maxSections: Maximum all-pass sections to fit. Default: 4.
    /// - Returns: All-pass BiquadCoefficients for the channel that needs correction.
    static func fitGroupDelayAllPass(
        delayErrorMs: [Double],
        applyToChannelA: Bool,
        crossoverHz: Double,
        frequencies: [Double],
        sampleRate: Double,
        maxSections: Int = 4
    ) -> [BiquadCoefficients] {
        let signMultiplier: Double = applyToChannelA ? -1.0 : 1.0
        let effectiveError = delayErrorMs.map { $0 * signMultiplier }
        guard effectiveError.contains(where: { $0 > 0.1 }) else { return [] }

        var residualError = effectiveError
        var coefficients: [BiquadCoefficients] = []

        let lowWeightFreq  = crossoverHz / 2.0
        let highWeightFreq = crossoverHz * 2.0

        let weights: [Double] = frequencies.map { f in
            (f >= lowWeightFreq && f <= highWeightFreq) ? 1.0 : 0.1
        }

        // Cost function: weighted squared residual after subtracting this (freq, Q) all-pass.
        // Uses the analytical group delay formula for speed and smoothness.
        func costForSection(freq: Double, q: Double) -> Double {
            let omega = 2.0 * Double.pi * freq / sampleRate
            let alpha = sin(omega) / (2.0 * q)
            let a0    = 1.0 + alpha
            let a1    = -2.0 * cos(omega) / a0
            let a2    = (1.0 - alpha) / a0
            let delay = allPassGroupDelayAnalytical(
                a1: a1, a2: a2, frequencies: frequencies, sampleRate: sampleRate)
            var cost = 0.0
            for i in frequencies.indices {
                let remaining = residualError[i] - delay[i]
                cost += weights[i] * remaining * remaining
            }
            return cost
        }

        for _ in 0..<maxSections {
            let peakWeightedError = zip(residualError, weights).map { $0 * $1 }.max() ?? 0
            guard peakWeightedError > 0.1 else { break }

            // Initial guess: frequency at peak weighted residual, Q = 1.0
            var initialFreq = crossoverHz
            var maxWE = 0.0
            for (i, f) in frequencies.enumerated() {
                let we = residualError[i] * weights[i]
                if we > maxWE { maxWE = we; initialFreq = f }
            }

            let fLow  = max(20.0, crossoverHz / 10.0)
            let fHigh = min(sampleRate * 0.45, crossoverHz * 10.0)

            let (bestFreq, bestQ) = nelderMead2D(
                initialX: initialFreq, initialY: 1.0,
                xMin: fLow,  xMax: fHigh,
                yMin: 0.3,   yMax: 6.0,
                initialStepX: max(initialFreq * 0.2, 50.0),
                initialStepY: 0.5,
                maxIterations: 150,
                tolerance: 0.5,
                costFunction: costForSection
            )

            let bestCoeffs = BiquadMath.calculateCoefficients(
                type: .allPass, sampleRate: sampleRate,
                frequency: bestFreq, q: bestQ, gain: 0.0)
            coefficients.append(bestCoeffs)

            // Subtract chosen section's analytical delay from residual.
            let omega   = 2.0 * Double.pi * bestFreq / sampleRate
            let alpha   = sin(omega) / (2.0 * bestQ)
            let a0norm  = 1.0 + alpha
            let a1      = -2.0 * cos(omega) / a0norm
            let a2      = (1.0 - alpha) / a0norm
            let chosenDelay = allPassGroupDelayAnalytical(
                a1: a1, a2: a2, frequencies: frequencies, sampleRate: sampleRate)
            for i in residualError.indices { residualError[i] -= chosenDelay[i] }
        }

        return coefficients
    }
}
