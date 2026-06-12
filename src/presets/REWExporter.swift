// REWExporter.swift
// Exports the current EQ band configuration to REW (Room EQ Wizard) filter text format.
// Format is the plain-text filter list understood by REW's "Import Filters" function
// and by MiniDSP plugin filter import.

import Foundation

enum REWExporter {

    /// Exports `bands` to a REW-compatible filter text string.
    ///
    /// REW filter format (one line per band):
    /// ```
    /// Filter  1: ON  PK       Fc    80 Hz  Gain  -6.0 dB  Q  4.00
    /// Filter  2: ON  LS       Fc    80 Hz  Gain   3.0 dB  Q  0.71
    /// Filter  3: ON  HS       Fc  8000 Hz  Gain  -1.5 dB  Q  0.71
    /// Filter  4: OFF PK       Fc   200 Hz  Gain   0.0 dB  Q  1.00
    /// ```
    /// Filter type codes: PK = parametric, LP = low-pass, HP = high-pass,
    /// LS = low shelf, HS = high shelf, NO = notch.
    static func export(bands: [EQBandConfiguration], channelLabel: String = "Left") -> String {
        var lines = ["# Equaliser export for \(channelLabel) channel"]
        lines.append("# Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        for (index, band) in bands.enumerated() {
            let onOff = band.bypass ? "OFF" : "ON "
            let typeCode = rewTypeCode(for: band.filterType, slope: band.slope)
            let fc   = Int(band.frequency.rounded())
            let gain = String(format: "%.1f", band.gain)
            let q    = String(format: "%.2f", band.q)
            let n    = String(format: "%2d", index + 1)
            lines.append("Filter \(n): \(onOff) \(typeCode)  Fc \(String(format: "%6d", fc)) Hz  Gain \(String(format: "%6s", gain)) dB  Q \(q)")
        }
        return lines.joined(separator: "\n")
    }

    private static func rewTypeCode(for type: FilterType, slope: FilterSlope) -> String {
        switch type {
        case .parametric:   return "PK      "
        case .lowPass:      return slope == .db12 ? "LP  Q   " : "BU LP   "
        case .highPass:     return slope == .db12 ? "HP  Q   " : "BU HP   "
        case .lowShelf:     return "LS      "
        case .highShelf:    return "HS      "
        case .notch:        return "NO      "
        case .allPass:      return "AP      "
        default:            return "PK      "
        }
    }
}
