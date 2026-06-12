// AutoEQExporter.swift
// Exports the current EQ configuration to the AutoEQ GraphicEQ / ParametricEQ text format
// as used by AutoEQ (https://autoeq.app) and compatible tools (Wavelet, EQ APO, Peace).

import Foundation

enum AutoEQExporter {

    /// Exports bands to AutoEQ ParametricEQ text format.
    ///
    /// Format:
    /// ```
    /// Preamp: -3.0 dB
    /// Filter 1: ON PK Fc 200 Hz Gain -6.0 dB Q 4.00
    /// Filter 2: ON LSC Fc 80 Hz Gain 3.0 dB Q 0.71
    /// ```
    static func exportParametricEQ(
        bands: [EQBandConfiguration],
        preampDB: Float = 0.0
    ) -> String {
        var lines = [String]()
        let preampStr = String(format: "%.1f", preampDB)
        lines.append("Preamp: \(preampStr) dB")
        for (i, band) in bands.enumerated() where !band.bypass {
            let typeStr = autoEQTypeString(for: band.filterType, slope: band.slope)
            let gain    = String(format: "%.1f", band.gain)
            let q       = String(format: "%.2f", band.q)
            let fc      = Int(band.frequency.rounded())
            lines.append("Filter \(i + 1): ON \(typeStr) Fc \(fc) Hz Gain \(gain) dB Q \(q)")
        }
        return lines.joined(separator: "\n")
    }

    private static func autoEQTypeString(for type: FilterType, slope: FilterSlope) -> String {
        switch type {
        case .parametric:   return "PK"
        case .lowShelf:     return "LSC"
        case .highShelf:    return "HSC"
        case .highPass:     return "HPQ"
        case .lowPass:      return "LPQ"
        case .notch:        return "NO"
        case .allPass:      return "AP"
        default:            return "PK"
        }
    }
}
