// EQHeadroomCompensator.swift
// Static EQ/Correction preamp for gain staging (Part 8)
//
// Computes a static preamp gain to prevent EQ and correction boosts from causing clipping.
// This is a predictive, control-thread computation based on filter design data,
// complementary to the existing Dynamic Gain Rider (Auto-Headroom).

import Foundation

/// EQ Headroom Compensator for static gain staging (Part 8).
enum EQHeadroomCompensator {

    /// Computes the static preamp gain in dB to prevent clipping from EQ/correction boosts.
    /// - Parameters:
    ///   - eqLayer: Main EQ layer bands
    ///   - roomCorrectionLayer: Room correction bands
    ///   - targetCurve: Target curve for room correction
    ///   - lowBandGainDB: Low band (subwoofer) gain from bass management
    ///   - maxAttenuationDB: Maximum allowed attenuation (range 3–24 dB, default 12 dB)
    /// - Returns: Static preamp gain in dB (always ≤ 0, never positive, clamped by ceiling)
    static func computeStaticPreampDB(
        eqLayer: [PresetBand],
        roomCorrectionLayer: [PresetBand],
        targetCurve: [(frequency: Double, gainDB: Double)],
        lowBandGainDB: Float,
        maxAttenuationDB: Float = 12.0
    ) -> Float {
        let frequencies = generateFrequencyBins()
        var worstCaseBoostDB: Float = 0.0

        for (i, freq) in frequencies.enumerated() {
            // Accumulate as linear gain (multiply, not add dB) for accuracy.
            var linearGain: Double = 1.0
            linearGain *= pow(10.0, Double(computeLayerGain(at: Float(freq), bands: eqLayer)) / 20.0)
            linearGain *= pow(10.0, Double(computeLayerGain(at: Float(freq), bands: roomCorrectionLayer)) / 20.0)
            linearGain *= pow(10.0, Double(interpolateTargetCurve(at: freq, curve: targetCurve)) / 20.0)
            if freq < 300.0 {
                linearGain *= pow(10.0, Double(lowBandGainDB) / 20.0)
            }
            // Guard: a NaN/Inf result means a band's coefficients are malformed.
            // Treat this as the worst possible case (maximum caution) rather than
            // silently ignoring it — never under-protect against a poisoned band.
            guard linearGain.isFinite else {
                worstCaseBoostDB = max(worstCaseBoostDB, 24.0)
                continue
            }
            let binBoostDB = Float(20.0 * log10(max(linearGain, 1e-10)))
            if !binBoostDB.isFinite {
                worstCaseBoostDB = max(worstCaseBoostDB, 24.0)
                continue
            }
            if binBoostDB > worstCaseBoostDB { worstCaseBoostDB = binBoostDB }
        }

        let clampedWorstCase = min(worstCaseBoostDB, max(3.0, maxAttenuationDB))
        return -max(0.0, clampedWorstCase)
    }

    /// Generates frequency bins for analysis (20 Hz - 96 kHz, log-spaced).
    private static func generateFrequencyBins(maxHz: Double = 96_000.0) -> [Double] {
        let minFreq = 20.0
        let maxFreq = maxHz
        let bins    = 200  // More bins for better resolution above 20 kHz
        return (0..<bins).map { i in
            pow(10.0, log10(minFreq) + Double(i) / Double(bins - 1) * log10(maxFreq / minFreq))
        }
    }

    /// Computes the gain of a filter layer at a specific frequency.
    private static func computeLayerGain(at frequency: Float, bands: [PresetBand]) -> Float {
        var totalGain: Float = 0.0

        for band in bands {
            if band.bypass { continue }

            let bandGain = computeBandGain(at: frequency, band: band)
            totalGain += bandGain
        }

        return totalGain
    }

    /// Computes the gain of a single band at a specific frequency.
    private static func computeBandGain(at frequency: Float, band: PresetBand) -> Float {
        guard !band.bypass else { return 0.0 }
        let coefficients: BiquadCoefficients
        if band.filterType == .parametric && band.constantQ {
            coefficients = BiquadMath.peakingEQConstantQ(
                sampleRate: 48_000.0,
                frequency: Double(band.frequency),
                q: Double(band.q),
                gain: Double(band.gain)
            )
        } else if band.filterType == .linkwitzTransform {
            let fp = band.linkwitzTargetHz.map { Double($0) } ?? (Double(band.frequency) * 0.7)
            coefficients = BiquadMath.linkwitzTransform(
                f0: Double(band.frequency), q0: Double(band.q),
                fp: fp, qp: Double(band.gain),
                sampleRate: 48_000.0
            )
        } else {
            switch band.filterType {
            case .parametric, .lowShelf, .highShelf, .lowPass, .highPass, .bandPass, .notch:
                coefficients = BiquadMath.calculateCoefficients(
                    type: band.filterType,
                    sampleRate: 48_000.0,
                    frequency: Double(band.frequency),
                    q: Double(band.q),
                    gain: Double(band.gain)
                )
            default:
                return 0.0
            }
        }
        let db = BiquadMath.magnitudeDB(coefficients: coefficients,
                                        atFrequency: Double(frequency),
                                        sampleRate: 48_000.0)
        return db.isFinite ? Float(db) : 0.0
    }

    /// Interpolates the target curve at a specific frequency.
    private static func interpolateTargetCurve(at frequency: Double, curve: [(frequency: Double, gainDB: Double)]) -> Double {
        guard !curve.isEmpty else { return 0.0 }
        guard curve.count > 1 else { return curve[0].gainDB }

        // Find the two points to interpolate between (linear in log-frequency space)
        let logFreq = log10(frequency)

        var lowIdx = 0
        var highIdx = curve.count - 1

        // Binary search for the interpolation interval
        while lowIdx < highIdx {
            let midIdx = (lowIdx + highIdx) / 2
            let midLogFreq = log10(curve[midIdx].frequency)
            if logFreq < midLogFreq {
                highIdx = midIdx
            } else {
                lowIdx = midIdx + 1
            }
        }

        // Clamp to valid range
        if lowIdx == 0 {
            lowIdx = 1
        }
        if lowIdx >= curve.count {
            lowIdx = curve.count - 1
        }

        let p0 = curve[lowIdx - 1]
        let p1 = curve[lowIdx]

        // Linear interpolation in log-frequency space
        let logFreq0 = log10(p0.frequency)
        let logFreq1 = log10(p1.frequency)
        let t = (logFreq - logFreq0) / (logFreq1 - logFreq0)
        let clampedT = max(0.0, min(1.0, t))

        return p0.gainDB + clampedT * (p1.gainDB - p0.gainDB)
    }
}
