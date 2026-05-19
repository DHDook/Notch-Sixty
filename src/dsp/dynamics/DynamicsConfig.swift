import Foundation

// MARK: - Soft Clipper Configuration

/// Configuration for the soft clipper wave-shaper stage.
struct SoftClipperConfig: Codable, Equatable, Sendable {
    /// Whether the soft clipper is active. Default OFF.
    var isEnabled: Bool = false

    /// Input drive applied before the wave-shaper, in dB.
    /// Range: -6.0 dB to +18.0 dB. Default: 0.0 dB.
    var driveDB: Float = 0.0

    /// Clipping threshold, in dB.
    /// Range: -12.0 dB to 0.0 dB. Default: -1.5 dB.
    var thresholdDB: Float = -1.5

    /// Knee smoothness controlling the width of the soft-knee transition region.
    /// Range: 0.001 (hard knee) to 1.0 (wide, tube-like saturation). Default: 0.5.
    var kneeSmooth: Float = 0.5

    static let `default` = SoftClipperConfig()
}

// MARK: - Brickwall Limiter Configuration

/// Configuration for the look-ahead brickwall limiter.
struct BrickwallLimiterConfig: Codable, Equatable, Sendable {
    /// Whether the limiter is active. Default ON.
    var isEnabled: Bool = true

    /// Output ceiling — the absolute peak the limiter will allow through, in dB.
    /// Range: -6.0 dB to 0.0 dB. Default: -0.2 dB.
    var ceilingDB: Float = -0.2

    /// Gain reduction attack time, in milliseconds.
    /// Range: 0.0 ms to 10.0 ms. Default: 0.1 ms.
    var attackMs: Float = 0.1

    /// Gain reduction release time, in milliseconds.
    /// Range: 5.0 ms to 250.0 ms. Default: 20.0 ms.
    var releaseMs: Float = 20.0

    /// Look-ahead anticipation window, in milliseconds.
    /// Range: 0.5 ms to 10.0 ms. Default: 2.0 ms.
    var lookAheadMs: Float = 2.0

    static let `default` = BrickwallLimiterConfig()

    // MARK: - Codable (forward-compatible)

    private enum CodingKeys: String, CodingKey {
        case isEnabled, ceilingDB, attackMs, releaseMs, lookAheadMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled  = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)   ?? true
        ceilingDB  = try c.decodeIfPresent(Float.self, forKey: .ceilingDB)   ?? -0.2
        attackMs   = try c.decodeIfPresent(Float.self, forKey: .attackMs)    ?? 0.1
        releaseMs  = try c.decodeIfPresent(Float.self, forKey: .releaseMs)   ?? 20.0
        lookAheadMs = try c.decodeIfPresent(Float.self, forKey: .lookAheadMs) ?? 2.0
    }
}

// MARK: - Combined Dynamics Configuration

/// Top-level dynamics configuration: soft clipper followed by brickwall limiter.
/// Placed at the end of the signal chain after all EQ and gain stages.
struct DynamicsConfig: Codable, Equatable, Sendable {
    var softClipper: SoftClipperConfig = .default
    var limiter: BrickwallLimiterConfig = .default

    static let `default` = DynamicsConfig()
}
