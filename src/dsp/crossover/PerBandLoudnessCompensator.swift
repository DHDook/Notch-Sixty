// PerBandLoudnessCompensator.swift
//
// Per-band loudness compensation based on ISO 226:2003 equal-loudness contours.
// Independently adjusts bass and treble band levels based on listening volume.

import Foundation

/// Per-band loudness compensation using ISO 226:2003 equal-loudness contours.
/// Provides frequency-dependent gain correction based on listening level (phons).
enum PerBandLoudnessCompensator {

    // MARK: - ISO 226:2003 Equal-Loudness Contours

    /// ISO 226:2003 equal-loudness contour lookup table.
    /// Frequencies in Hz, SPL in dB for phons levels 20, 40, 60, 80, 100.
    private static let iso226Frequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
        630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
        10000, 12500
    ]

    private static let iso226Contours: [[Double]] = [
        // 20 phons
        [78.5, 68.7, 59.5, 51.3, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9, 14.4, 11.4,
         8.6, 6.2, 4.4, 3.0, 2.2, 2.4, 3.5, 4.7, 5.6, 6.0, 5.9, 5.3, 4.5, 3.6,
         2.9, 2.4],
        // 40 phons
        [67.1, 58.5, 50.6, 43.5, 37.5, 32.0, 27.0, 22.5, 18.8, 15.0, 12.0, 9.3,
         7.1, 5.4, 4.0, 2.9, 2.3, 2.6, 3.9, 5.2, 6.3, 6.8, 6.7, 6.0, 5.0, 4.0,
         3.2, 2.7],
        // 60 phons
        [56.7, 49.5, 42.9, 37.0, 32.0, 27.5, 23.5, 19.8, 16.5, 13.0, 10.3, 8.0,
         6.2, 4.8, 3.8, 3.0, 2.5, 2.9, 4.3, 5.8, 7.0, 7.6, 7.5, 6.8, 5.8, 4.7,
         3.8, 3.1],
        // 80 phons
        [48.4, 42.5, 37.2, 32.5, 28.5, 25.0, 21.5, 18.5, 15.5, 12.5, 10.0, 8.0,
         6.5, 5.3, 4.5, 3.8, 3.5, 4.0, 5.4, 7.0, 8.4, 9.0, 8.9, 8.2, 7.2, 6.1,
         5.0, 4.2],
        // 100 phons
        [41.7, 37.2, 33.0, 29.5, 26.5, 23.5, 20.5, 18.0, 15.5, 13.0, 10.8, 9.0,
         7.5, 6.5, 5.8, 5.3, 5.0, 5.5, 6.8, 8.4, 9.9, 10.5, 10.4, 9.7, 8.7, 7.6,
         6.5, 5.6]
    ]

    /// Interpolates ISO 226:2003 equal-loudness contour at a given frequency and phon level.
    /// - Parameters:
    ///   - frequencyHz: Frequency in Hz (20–12500)
    ///   - phons: Phon level (20–100)
    /// - Returns: SPL in dB for the given frequency and phon level
    static func iso226SPL(frequencyHz: Double, phons: Double) -> Double {
        guard frequencyHz >= 20 && frequencyHz <= 12500 else { return 0.0 }
        guard phons >= 20 && phons <= 100 else { return 0.0 }

        // Clamp phons to valid range
        let clampedPhons = max(20, min(100, phons))

        // Find the two phon levels to interpolate between
        let lowerPhonIndex = Int((clampedPhons - 20) / 20)
        let upperPhonIndex = min(lowerPhonIndex + 1, iso226Contours.count - 1)
        let phonFraction = (clampedPhons - 20).truncatingRemainder(dividingBy: 20) / 20.0

        // Interpolate between the two phon levels
        let lowerContour = iso226Contours[lowerPhonIndex]
        let upperContour = iso226Contours[upperPhonIndex]

        // Find the two frequency points to interpolate between
        let freqIndex = findFrequencyIndex(frequencyHz)
        let lowerFreq = iso226Frequencies[freqIndex]
        let upperFreq = iso226Frequencies[min(freqIndex + 1, iso226Frequencies.count - 1)]
        let freqFraction = (frequencyHz - lowerFreq) / (upperFreq - lowerFreq)

        // Interpolate SPL at the lower phon level
        let lowerSPL = lowerContour[freqIndex] * (1.0 - freqFraction) +
                       lowerContour[min(freqIndex + 1, lowerContour.count - 1)] * freqFraction

        // Interpolate SPL at the upper phon level
        let upperSPL = upperContour[freqIndex] * (1.0 - freqFraction) +
                       upperContour[min(freqIndex + 1, upperContour.count - 1)] * freqFraction

        // Interpolate between the two phon levels
        return lowerSPL * (1.0 - phonFraction) + upperSPL * phonFraction
    }

    private static func findFrequencyIndex(_ frequencyHz: Double) -> Int {
        for i in 0..<iso226Frequencies.count - 1 {
            if frequencyHz >= iso226Frequencies[i] && frequencyHz <= iso226Frequencies[i + 1] {
                return i
            }
        }
        return iso226Frequencies.count - 2
    }

    // MARK: - Gain Correction

    /// Calculates gain correction for a given signal source based on current and reference phon levels.
    /// - Parameters:
    ///   - source: Signal source (determines passband centre frequency)
    ///   - currentPhons: Current listening level in phons
    ///   - referencePhons: Reference phon level (zero correction at this level)
    ///   - activeCrossover: Active crossover configuration
    ///   - bassManagementCrossoverHz: Bass management crossover frequency in Hz
    ///   - config: Per-band loudness configuration
    /// - Returns: Gain correction in dB (clamped to [-maxCutDB, +maxBoostDB])
    static func gainCorrection(
        source: SignalSource,
        currentPhons: Double,
        referencePhons: Double,
        activeCrossover: ActiveCrossoverConfig,
        bassManagementCrossoverHz: Float,
        config: PerBandLoudnessConfig
    ) -> Float {
        // Determine passband centre frequency per source
        let centreFrequency: Double
        switch source {
        case .mainsLeft, .mainsRight:
            // Full-range mains: no correction
            return 0.0
        case .mainsLeftLow, .mainsRightLow:
            // Low band: lower crossover / 2
            if activeCrossover.bandCount == .biAmp {
                centreFrequency = Double(activeCrossover.lowerPoint.lpHz) / 2.0
            } else if activeCrossover.bandCount == .triAmp {
                centreFrequency = Double(activeCrossover.lowerPoint.lpHz) / 2.0
            } else {
                centreFrequency = 100.0 // fallback
            }
        case .mainsLeftMid, .mainsRightMid:
            // Mid band: geometric mean of lower/upper crossover
            if activeCrossover.bandCount == .triAmp {
                let lower = Double(activeCrossover.lowerPoint.lpHz)
                let upper = Double(activeCrossover.upperPoint.lpHz)
                centreFrequency = sqrt(lower * upper)
            } else {
                centreFrequency = 1000.0 // fallback
            }
        case .mainsLeftHigh, .mainsRightHigh:
            // High band: upper crossover × 2
            if activeCrossover.bandCount == .biAmp {
                centreFrequency = Double(activeCrossover.lowerPoint.lpHz) * 2.0
            } else if activeCrossover.bandCount == .triAmp {
                centreFrequency = Double(activeCrossover.upperPoint.lpHz) * 2.0
            } else {
                centreFrequency = 5000.0 // fallback
            }
        case .subMono:
            // Subwoofer: bass management crossover / 2
            centreFrequency = Double(bassManagementCrossoverHz) / 2.0
        }

        // Calculate correction using ISO 226:2003
        let referenceSPL = iso226SPL(frequencyHz: centreFrequency, phons: referencePhons)
        let currentSPL = iso226SPL(frequencyHz: centreFrequency, phons: currentPhons)
        let correctionDB = referenceSPL - currentSPL

        // Clamp to configured limits
        let correctionFloat = Float(correctionDB)
        return max(-config.maxCutDB, min(config.maxBoostDB, correctionFloat))
    }

    // MARK: - Phon Level from System Volume

    /// Converts system volume scalar (0.0–1.0) to phon level.
    /// - Parameters:
    ///   - volume: System volume scalar (0.0–1.0)
    ///   - referencePhons: Reference phon level
    /// - Returns: Phon level (20–100)
    static func phonsFromSystemVolume(_ volume: Double, referencePhons: Double) -> Double {
        let logVolume = log10(max(0.001, volume))
        let phons = referencePhons + 20.0 * logVolume
        return max(20, min(100, phons))
    }
}
