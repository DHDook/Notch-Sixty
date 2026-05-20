import Foundation

// MARK: - De-Esser Configuration

/// Configuration for the frequency-selective de-esser.
struct DeEsserConfig: Codable, Equatable, Sendable {
    /// Whether the de-esser is active. Default OFF.
    var isEnabled: Bool = false
    /// Sidechain bandpass centre frequency in Hz. Range: 2000–10000 Hz. Default: 6000 Hz.
    var frequencyHz: Float = 6000.0
    /// Sidechain detection threshold in dBFS. Range: −60–0 dB. Default: −20 dB.
    var thresholdDB: Float = -20.0

    static let `default` = DeEsserConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, frequencyHz, thresholdDB
    }

    init(isEnabled: Bool = false, frequencyHz: Float = 6000.0, thresholdDB: Float = -20.0) {
        self.isEnabled = isEnabled
        self.frequencyHz = frequencyHz
        self.thresholdDB = thresholdDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled    = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)    ?? false
        frequencyHz  = try c.decodeIfPresent(Float.self, forKey: .frequencyHz)  ?? 6000.0
        thresholdDB  = try c.decodeIfPresent(Float.self, forKey: .thresholdDB)  ?? -20.0
    }
}

// MARK: - Multiband Compressor Configuration

/// Configuration for the three-band Linkwitz-Riley multiband compressor.
struct MultibandCompressorConfig: Codable, Equatable, Sendable {
    /// Whether the multiband compressor is active. Default OFF.
    var isEnabled: Bool = false
    /// Low/mid crossover frequency in Hz. Range: 40–250 Hz. Default: 150 Hz.
    var crossLowMidHz: Float = 150.0
    /// Mid/high crossover frequency in Hz. Range: 1000–8000 Hz. Default: 3000 Hz.
    var crossMidHighHz: Float = 3000.0
    /// Low-band compression threshold in dBFS. Range: −60–0 dB. Default: 0 dB (inactive).
    var thresholdLowDB: Float = 0.0
    /// Mid-band compression threshold in dBFS. Range: −60–0 dB. Default: 0 dB (inactive).
    var thresholdMidDB: Float = 0.0
    /// High-band compression threshold in dBFS. Range: −60–0 dB. Default: 0 dB (inactive).
    var thresholdHighDB: Float = 0.0

    static let `default` = MultibandCompressorConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, crossLowMidHz, crossMidHighHz, thresholdLowDB, thresholdMidDB, thresholdHighDB
    }

    init(
        isEnabled: Bool = false,
        crossLowMidHz: Float = 150.0,
        crossMidHighHz: Float = 3000.0,
        thresholdLowDB: Float = 0.0,
        thresholdMidDB: Float = 0.0,
        thresholdHighDB: Float = 0.0
    ) {
        self.isEnabled = isEnabled
        self.crossLowMidHz = crossLowMidHz
        self.crossMidHighHz = crossMidHighHz
        self.thresholdLowDB = thresholdLowDB
        self.thresholdMidDB = thresholdMidDB
        self.thresholdHighDB = thresholdHighDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled       = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)       ?? false
        crossLowMidHz   = try c.decodeIfPresent(Float.self, forKey: .crossLowMidHz)   ?? 150.0
        crossMidHighHz  = try c.decodeIfPresent(Float.self, forKey: .crossMidHighHz)  ?? 3000.0
        thresholdLowDB  = try c.decodeIfPresent(Float.self, forKey: .thresholdLowDB)  ?? 0.0
        thresholdMidDB  = try c.decodeIfPresent(Float.self, forKey: .thresholdMidDB)  ?? 0.0
        thresholdHighDB = try c.decodeIfPresent(Float.self, forKey: .thresholdHighDB) ?? 0.0
    }
}

// MARK: - Compressor Configuration

/// Configuration for the wideband feed-forward compressor.
struct CompressorConfig: Codable, Equatable, Sendable {
    /// Whether the compressor is active. Default OFF.
    var isEnabled: Bool = false
    /// Compression threshold in dBFS. Range: −60–0 dB. Default: −16 dB.
    var thresholdDB: Float = -16.0
    /// Compression ratio (x:1). Range: 1–20. Default: 3.5.
    var ratio: Float = 3.5
    /// Gain reduction attack time in milliseconds. Range: 0.1–100 ms. Default: 25 ms.
    var attackMs: Float = 25.0
    /// Gain reduction release time in milliseconds. Range: 5–1000 ms. Default: 150 ms.
    var releaseMs: Float = 150.0
    /// Output makeup gain in dB. Range: 0–24 dB. Default: 2.5 dB.
    var makeupGainDB: Float = 2.5

    static let `default` = CompressorConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, thresholdDB, ratio, attackMs, releaseMs, makeupGainDB
    }

    init(
        isEnabled: Bool = false,
        thresholdDB: Float = -16.0,
        ratio: Float = 3.5,
        attackMs: Float = 25.0,
        releaseMs: Float = 150.0,
        makeupGainDB: Float = 2.5
    ) {
        self.isEnabled = isEnabled
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.makeupGainDB = makeupGainDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled    = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)    ?? false
        thresholdDB  = try c.decodeIfPresent(Float.self, forKey: .thresholdDB)  ?? -16.0
        ratio        = try c.decodeIfPresent(Float.self, forKey: .ratio)        ?? 3.5
        attackMs     = try c.decodeIfPresent(Float.self, forKey: .attackMs)     ?? 25.0
        releaseMs    = try c.decodeIfPresent(Float.self, forKey: .releaseMs)    ?? 150.0
        makeupGainDB = try c.decodeIfPresent(Float.self, forKey: .makeupGainDB) ?? 2.5
    }
}

// MARK: - Expander Configuration

/// Configuration for the downward dynamic-range expander.
struct ExpanderConfig: Codable, Equatable, Sendable {
    /// Whether the expander is active. Default OFF.
    var isEnabled: Bool = false
    /// Expansion threshold in dBFS. Range: −60–0 dB. Default: −35 dB.
    var thresholdDB: Float = -35.0
    /// Expansion ratio (downward factor). Range: 1–4. Default: 1.5.
    var ratio: Float = 1.5
    /// Maximum attenuation ceiling in dB (negative). Range: −40–0 dB. Default: −12 dB.
    var rangeDB: Float = -12.0

    static let `default` = ExpanderConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, thresholdDB, ratio, rangeDB
    }

    init(isEnabled: Bool = false, thresholdDB: Float = -35.0, ratio: Float = 1.5, rangeDB: Float = -12.0) {
        self.isEnabled = isEnabled
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.rangeDB = rangeDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)   ?? false
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -35.0
        ratio       = try c.decodeIfPresent(Float.self, forKey: .ratio)       ?? 1.5
        rangeDB     = try c.decodeIfPresent(Float.self, forKey: .rangeDB)     ?? -12.0
    }
}

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

    init(
        isEnabled: Bool = true,
        ceilingDB: Float = -0.2,
        attackMs: Float = 0.1,
        releaseMs: Float = 20.0,
        lookAheadMs: Float = 2.0
    ) {
        self.isEnabled = isEnabled
        self.ceilingDB = ceilingDB
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.lookAheadMs = lookAheadMs
    }

    static let `default` = BrickwallLimiterConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, ceilingDB, attackMs, releaseMs, lookAheadMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)    ?? true
        ceilingDB   = try c.decodeIfPresent(Float.self, forKey: .ceilingDB)    ?? -0.2
        attackMs    = try c.decodeIfPresent(Float.self, forKey: .attackMs)     ?? 0.1
        releaseMs   = try c.decodeIfPresent(Float.self, forKey: .releaseMs)    ?? 20.0
        lookAheadMs = try c.decodeIfPresent(Float.self, forKey: .lookAheadMs)  ?? 2.0
    }
}

// MARK: - Combined Dynamics Configuration

/// Full dynamics configuration covering all six stages of the signal chain:
/// De-Esser → Multiband Compressor → Compressor → Expander → Soft Clipper → Brickwall Limiter.
///
/// All fields use `decodeIfPresent` so presets saved before a field was introduced
/// load cleanly and fall back to the safe neutral default for that stage.
struct DynamicsConfig: Codable, Equatable, Sendable {
    var deEsser: DeEsserConfig = .default
    var multibandCompressor: MultibandCompressorConfig = .default
    var compressor: CompressorConfig = .default
    var expander: ExpanderConfig = .default
    var softClipper: SoftClipperConfig = .default
    var limiter: BrickwallLimiterConfig = .default

    static let `default` = DynamicsConfig()

    private enum CodingKeys: String, CodingKey {
        case deEsser, multibandCompressor, compressor, expander, softClipper, limiter
    }

    init(
        deEsser: DeEsserConfig = .default,
        multibandCompressor: MultibandCompressorConfig = .default,
        compressor: CompressorConfig = .default,
        expander: ExpanderConfig = .default,
        softClipper: SoftClipperConfig = .default,
        limiter: BrickwallLimiterConfig = .default
    ) {
        self.deEsser = deEsser
        self.multibandCompressor = multibandCompressor
        self.compressor = compressor
        self.expander = expander
        self.softClipper = softClipper
        self.limiter = limiter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deEsser             = try c.decodeIfPresent(DeEsserConfig.self,             forKey: .deEsser)             ?? .default
        multibandCompressor = try c.decodeIfPresent(MultibandCompressorConfig.self, forKey: .multibandCompressor) ?? .default
        compressor          = try c.decodeIfPresent(CompressorConfig.self,          forKey: .compressor)          ?? .default
        expander            = try c.decodeIfPresent(ExpanderConfig.self,            forKey: .expander)            ?? .default
        softClipper         = try c.decodeIfPresent(SoftClipperConfig.self,         forKey: .softClipper)         ?? .default
        limiter             = try c.decodeIfPresent(BrickwallLimiterConfig.self,    forKey: .limiter)             ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deEsser,             forKey: .deEsser)
        try c.encode(multibandCompressor, forKey: .multibandCompressor)
        try c.encode(compressor,          forKey: .compressor)
        try c.encode(expander,            forKey: .expander)
        try c.encode(softClipper,         forKey: .softClipper)
        try c.encode(limiter,             forKey: .limiter)
    }
}
