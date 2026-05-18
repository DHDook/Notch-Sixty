/// Filter slope in dB per octave.
///
/// Applies to Low Pass, High Pass, Low Shelf, and High Shelf filter types only.
/// For other filter types the slope setting is hidden and has no effect.
///
/// Higher slopes require cascading multiple biquad sections:
///   - 6 dB/oct  → 1st-order (single degenerate biquad, b2=a2=0)
///   - 12 dB/oct → 2nd-order (1 biquad section, default)
///   - 24 dB/oct → 4th-order (2 cascaded Butterworth biquad sections)
///   - 48 dB/oct → 8th-order (4 cascaded Butterworth biquad sections)
enum FilterSlope: Int, Codable, Sendable, CaseIterable {
    case db6  = 6
    case db12 = 12
    case db24 = 24
    case db48 = 48

    // MARK: - Display

    var displayName: String {
        switch self {
        case .db6:  return "6 dB/oct"
        case .db12: return "12 dB/oct"
        case .db24: return "24 dB/oct"
        case .db48: return "48 dB/oct"
        }
    }

    // MARK: - Section Count

    /// Number of biquad sections required to achieve this slope.
    var sectionCount: Int {
        switch self {
        case .db6:  return 1
        case .db12: return 1
        case .db24: return 2
        case .db48: return 4
        }
    }

    // MARK: - Butterworth Q Values (LP / HP)

    /// Per-section Butterworth Q values for LP and HP cascades.
    ///
    /// For a Butterworth filter of order N, the Q for the k-th second-order section is:
    ///   Q_k = 1 / (2 * sin((2k−1) * π / (2N)))  for k = 1 … N/2
    ///
    /// The 6 dB/oct case uses a 1st-order bilinear section — Q is unused.
    var butterworthQValues: [Double] {
        switch self {
        case .db6:
            return []
        case .db12:
            // N=2, 1 section: Q = 1/(2*sin(π/4)) = 1/√2
            return [0.7071067811865476]
        case .db24:
            // N=4, 2 sections:
            // Q1 = 1/(2*sin(π/8))  ≈ 1.3066
            // Q2 = 1/(2*sin(3π/8)) ≈ 0.5412
            return [1.3065629648763766, 0.5411961001063831]
        case .db48:
            // N=8, 4 sections:
            // Q1 = 1/(2*sin(π/16))  ≈ 2.5629
            // Q2 = 1/(2*sin(3π/16)) ≈ 0.8999
            // Q3 = 1/(2*sin(5π/16)) ≈ 0.6013
            // Q4 = 1/(2*sin(7π/16)) ≈ 0.5098
            return [2.5629154477415234, 0.8999762281654536, 0.6013439465698173, 0.5097955791041592]
        }
    }

    // MARK: - Support Check

    /// Whether slope control is meaningful for a given filter type.
    static func isSupported(for filterType: FilterType) -> Bool {
        switch filterType {
        case .lowPass, .highPass, .lowShelf, .highShelf:
            return true
        default:
            return false
        }
    }
}
