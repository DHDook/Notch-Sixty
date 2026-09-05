import Foundation

enum MainsNotchCoefficients {
    /// Default reduction depth taper: harmonic 1 (fundamental) gets the
    /// deepest cut; each subsequent harmonic gets 2 dB less, floored at
    /// -6 dB. This is a starting point — fully overridable per harmonic
    /// via the UI.
    static func defaultDepthsDB(count: Int) -> [Float] {
        (1...count).map { max(-24.0 + Float($0 - 1) * 2.0, -6.0) }
    }

    /// Q applied to every harmonic notch. Not per-harmonic in this version
    /// — a single global value keeps the UI scope reasonable while still
    /// giving real control over notch width.
    static let defaultQ: Float = 30.0

    /// Builds one BiquadCoefficients section per active harmonic.
    /// harmonicDepthsDB.count must be >= harmonicCount; extra entries are
    /// ignored.
    static func buildSections(
        fundamentalHz: Double, sampleRate: Double,
        harmonicCount: Int, harmonicDepthsDB: [Float], q: Float
    ) -> [BiquadCoefficients] {
        (1...harmonicCount).map { harmonic in
            let freq = fundamentalHz * Double(harmonic)
            let depth = harmonic - 1 < harmonicDepthsDB.count ? harmonicDepthsDB[harmonic - 1] : -6.0
            return BiquadMath.peakingEQ(
                sampleRate: sampleRate, frequency: freq,
                q: Double(q), gain: Double(depth)
            )
        }
    }
}
