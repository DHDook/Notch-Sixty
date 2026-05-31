import Foundation

// MARK: - Crossover Slope

/// Linkwitz-Riley crossover slope for the multiband compressor.
enum CrossoverSlope: Int, Codable, Equatable, Sendable {
    /// 4th-order LR (24 dB/oct) — two cascaded 2nd-order Butterworth stages.
    case gentle = 0
    /// 8th-order LR (48 dB/oct) — four cascaded 2nd-order Butterworth stages.
    case steep  = 1
}

// MARK: - De-Esser Configuration

/// Configuration for the frequency-selective de-esser.
struct DeEsserConfig: Codable, Equatable, Sendable {
    var isEnabled:   Bool  = false
    var frequencyHz: Float = 6000.0
    var thresholdDB: Float = -20.0

    static let `default` = DeEsserConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, frequencyHz, thresholdDB
    }

    init(isEnabled: Bool = false, frequencyHz: Float = 6000.0, thresholdDB: Float = -20.0) {
        self.isEnabled   = isEnabled
        self.frequencyHz = frequencyHz
        self.thresholdDB = thresholdDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)   ?? false
        frequencyHz = try c.decodeIfPresent(Float.self, forKey: .frequencyHz) ?? 6000.0
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -20.0
    }
}

// MARK: - Multiband Compressor Configuration

/// Configuration for the three-band Linkwitz-Riley multiband compressor.
struct MultibandCompressorConfig: Codable, Equatable, Sendable {
    var isEnabled:       Bool            = false
    var crossLowMidHz:   Float           = 150.0
    var crossMidHighHz:  Float           = 3000.0
    var thresholdLowDB:  Float           = 0.0
    var thresholdMidDB:  Float           = 0.0
    var thresholdHighDB: Float           = 0.0
    /// Slope for the Low/Mid crossover. Default: gentle (LR4, 24 dB/oct).
    var slopeLowMid:     CrossoverSlope  = .gentle
    /// Slope for the Mid/High crossover. Default: gentle (LR4, 24 dB/oct).
    var slopeMidHigh:    CrossoverSlope  = .gentle

    static let `default` = MultibandCompressorConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, crossLowMidHz, crossMidHighHz
        case thresholdLowDB, thresholdMidDB, thresholdHighDB
        case slopeLowMid, slopeMidHigh
    }

    init(
        isEnabled: Bool = false,
        crossLowMidHz: Float = 150.0,
        crossMidHighHz: Float = 3000.0,
        thresholdLowDB: Float = 0.0,
        thresholdMidDB: Float = 0.0,
        thresholdHighDB: Float = 0.0,
        slopeLowMid: CrossoverSlope = .gentle,
        slopeMidHigh: CrossoverSlope = .gentle
    ) {
        self.isEnabled       = isEnabled
        self.crossLowMidHz   = crossLowMidHz
        self.crossMidHighHz  = crossMidHighHz
        self.thresholdLowDB  = thresholdLowDB
        self.thresholdMidDB  = thresholdMidDB
        self.thresholdHighDB = thresholdHighDB
        self.slopeLowMid     = slopeLowMid
        self.slopeMidHigh    = slopeMidHigh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled       = try c.decodeIfPresent(Bool.self,           forKey: .isEnabled)       ?? false
        crossLowMidHz   = try c.decodeIfPresent(Float.self,          forKey: .crossLowMidHz)   ?? 150.0
        crossMidHighHz  = try c.decodeIfPresent(Float.self,          forKey: .crossMidHighHz)  ?? 3000.0
        thresholdLowDB  = try c.decodeIfPresent(Float.self,          forKey: .thresholdLowDB)  ?? 0.0
        thresholdMidDB  = try c.decodeIfPresent(Float.self,          forKey: .thresholdMidDB)  ?? 0.0
        thresholdHighDB = try c.decodeIfPresent(Float.self,          forKey: .thresholdHighDB) ?? 0.0
        slopeLowMid     = try c.decodeIfPresent(CrossoverSlope.self, forKey: .slopeLowMid)     ?? .gentle
        slopeMidHigh    = try c.decodeIfPresent(CrossoverSlope.self, forKey: .slopeMidHigh)    ?? .gentle
    }
}

// MARK: - Compressor Configuration

/// Configuration for the wideband feed-forward compressor.
struct CompressorConfig: Codable, Equatable, Sendable {
    var isEnabled:      Bool  = false
    var thresholdDB:    Float = -16.0
    var ratio:          Float = 3.5
    var attackMs:       Float = 25.0
    var releaseMs:      Float = 150.0
    var makeupGainDB:   Float = 2.5
    /// Soft-knee transition width in dB. 0 = hard knee, 20 = maximum soft-knee.
    /// Default: 6.0 dB.
    var kneeWidthDB:    Float = 6.0

    static let `default` = CompressorConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, thresholdDB, ratio, attackMs, releaseMs, makeupGainDB, kneeWidthDB
    }

    init(
        isEnabled: Bool = false,
        thresholdDB: Float = -16.0,
        ratio: Float = 3.5,
        attackMs: Float = 25.0,
        releaseMs: Float = 150.0,
        makeupGainDB: Float = 2.5,
        kneeWidthDB: Float = 6.0
    ) {
        self.isEnabled    = isEnabled
        self.thresholdDB  = thresholdDB
        self.ratio        = ratio
        self.attackMs     = attackMs
        self.releaseMs    = releaseMs
        self.makeupGainDB = makeupGainDB
        self.kneeWidthDB  = kneeWidthDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled    = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)    ?? false
        thresholdDB  = try c.decodeIfPresent(Float.self, forKey: .thresholdDB)  ?? -16.0
        ratio        = try c.decodeIfPresent(Float.self, forKey: .ratio)        ?? 3.5
        attackMs     = try c.decodeIfPresent(Float.self, forKey: .attackMs)     ?? 25.0
        releaseMs    = try c.decodeIfPresent(Float.self, forKey: .releaseMs)    ?? 150.0
        makeupGainDB = try c.decodeIfPresent(Float.self, forKey: .makeupGainDB) ?? 2.5
        kneeWidthDB  = try c.decodeIfPresent(Float.self, forKey: .kneeWidthDB)  ?? 6.0
    }
}

// MARK: - Expander Configuration

/// Configuration for the downward dynamic-range expander.
struct ExpanderConfig: Codable, Equatable, Sendable {
    var isEnabled:   Bool  = false
    var thresholdDB: Float = -35.0
    var ratio:       Float = 1.5
    var rangeDB:     Float = -12.0

    static let `default` = ExpanderConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, thresholdDB, ratio, rangeDB
    }

    init(isEnabled: Bool = false, thresholdDB: Float = -35.0, ratio: Float = 1.5, rangeDB: Float = -12.0) {
        self.isEnabled   = isEnabled
        self.thresholdDB = thresholdDB
        self.ratio       = ratio
        self.rangeDB     = rangeDB
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
    var isEnabled:   Bool  = false
    var driveDB:     Float = 0.0
    var thresholdDB: Float = -1.5
    var kneeSmooth:  Float = 0.5

    static let `default` = SoftClipperConfig()
}

// MARK: - Brickwall Limiter Configuration

/// Configuration for the look-ahead brickwall limiter.
struct BrickwallLimiterConfig: Codable, Equatable, Sendable {
    var isEnabled:   Bool  = true
    var ceilingDB:   Float = -0.2
    var attackMs:    Float = 0.1
    var releaseMs:   Float = 20.0
    var lookAheadMs: Float = 2.0

    init(
        isEnabled: Bool = true,
        ceilingDB: Float = -0.2,
        attackMs: Float = 0.1,
        releaseMs: Float = 20.0,
        lookAheadMs: Float = 2.0
    ) {
        self.isEnabled   = isEnabled
        self.ceilingDB   = ceilingDB
        self.attackMs    = attackMs
        self.releaseMs   = releaseMs
        self.lookAheadMs = lookAheadMs
    }

    static let `default` = BrickwallLimiterConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, ceilingDB, attackMs, releaseMs, lookAheadMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)   ?? true
        ceilingDB   = try c.decodeIfPresent(Float.self, forKey: .ceilingDB)   ?? -0.2
        attackMs    = try c.decodeIfPresent(Float.self, forKey: .attackMs)    ?? 0.1
        releaseMs   = try c.decodeIfPresent(Float.self, forKey: .releaseMs)   ?? 20.0
        lookAheadMs = try c.decodeIfPresent(Float.self, forKey: .lookAheadMs) ?? 2.0
    }
}

// MARK: - Stereo Widener Configuration

/// Configuration for the three-band frequency-dependent stereo widener.
///
/// Uses hardcoded crossover frequencies of 200 Hz (Low/Mid) and 4000 Hz (Mid/High).
/// Width factors: 0 = pure mono, 1.0 = original stereo, 2.0 = maximum expansion.
struct StereoWidenerConfig: Codable, Equatable, Sendable {
    /// Whether the stereo widener is active. Default OFF.
    var isEnabled:      Bool  = false
    /// Low-band (< 200 Hz) width. Range: 0.0 (mono) – 1.0 (stereo). Default: 0.0 (mono bass).
    var widthFactorLow: Float = 0.0
    /// Mid-band (200 Hz – 4 kHz) width. Range: 1.0 – 2.0. Default: 1.4.
    var widthFactorMid: Float = 1.4
    /// High-band (> 4 kHz) width. Range: 1.0 – 2.0. Default: 1.25.
    var widthFactorHigh: Float = 1.25

    static let `default` = StereoWidenerConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, widthFactorLow, widthFactorMid, widthFactorHigh
    }

    init(
        isEnabled: Bool = false,
        widthFactorLow: Float = 0.0,
        widthFactorMid: Float = 1.4,
        widthFactorHigh: Float = 1.25
    ) {
        self.isEnabled      = isEnabled
        self.widthFactorLow  = widthFactorLow
        self.widthFactorMid  = widthFactorMid
        self.widthFactorHigh = widthFactorHigh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled       = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)       ?? false
        widthFactorLow  = try c.decodeIfPresent(Float.self, forKey: .widthFactorLow)  ?? 0.0
        widthFactorMid  = try c.decodeIfPresent(Float.self, forKey: .widthFactorMid)  ?? 1.4
        widthFactorHigh = try c.decodeIfPresent(Float.self, forKey: .widthFactorHigh) ?? 1.25
    }
}

// MARK: - Loudness Match Configuration

/// Configuration for real-time LUFS loudness matching.
struct LoudnessMatchConfig: Codable, Equatable, Sendable {
    /// Whether loudness matching is active. Default OFF.
    var isEnabled:        Bool  = false
    /// Target integrated loudness in LUFS. Range: −24 to −10 LUFS. Default: −16 LUFS.
    var targetLoudnessLUFS: Float = -16.0

    static let `default` = LoudnessMatchConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, targetLoudnessLUFS
    }

    init(isEnabled: Bool = false, targetLoudnessLUFS: Float = -16.0) {
        self.isEnabled          = isEnabled
        self.targetLoudnessLUFS = targetLoudnessLUFS
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled          = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)          ?? false
        targetLoudnessLUFS = try c.decodeIfPresent(Float.self, forKey: .targetLoudnessLUFS) ?? -16.0
    }
}

// MARK: - Combined Dynamics Configuration

/// Full dynamics configuration covering all processing stages.
///
/// Signal chain:
/// Stereo Widener → Loudness Match → De-Esser → Multiband Compressor
/// → Compressor → Expander → Soft Clipper → Brickwall Limiter.
///
/// All fields use `decodeIfPresent` so presets saved before a field was introduced
/// load cleanly and fall back to the safe neutral default for that stage.
struct DynamicsConfig: Codable, Equatable, Sendable {
    var stereoWidener:      StereoWidenerConfig      = .default
    var loudnessMatch:      LoudnessMatchConfig       = .default
    var deEsser:            DeEsserConfig             = .default
    var multibandCompressor: MultibandCompressorConfig = .default
    var compressor:         CompressorConfig          = .default
    var expander:           ExpanderConfig            = .default
    var softClipper:        SoftClipperConfig         = .default
    var limiter:            BrickwallLimiterConfig     = .default

    static let `default` = DynamicsConfig()

    private enum CodingKeys: String, CodingKey {
        case stereoWidener, loudnessMatch, deEsser, multibandCompressor
        case compressor, expander, softClipper, limiter
    }

    init(
        stereoWidener: StereoWidenerConfig = .default,
        loudnessMatch: LoudnessMatchConfig = .default,
        deEsser: DeEsserConfig = .default,
        multibandCompressor: MultibandCompressorConfig = .default,
        compressor: CompressorConfig = .default,
        expander: ExpanderConfig = .default,
        softClipper: SoftClipperConfig = .default,
        limiter: BrickwallLimiterConfig = .default
    ) {
        self.stereoWidener       = stereoWidener
        self.loudnessMatch       = loudnessMatch
        self.deEsser             = deEsser
        self.multibandCompressor = multibandCompressor
        self.compressor          = compressor
        self.expander            = expander
        self.softClipper         = softClipper
        self.limiter             = limiter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stereoWidener       = try c.decodeIfPresent(StereoWidenerConfig.self,      forKey: .stereoWidener)       ?? .default
        loudnessMatch       = try c.decodeIfPresent(LoudnessMatchConfig.self,      forKey: .loudnessMatch)       ?? .default
        deEsser             = try c.decodeIfPresent(DeEsserConfig.self,            forKey: .deEsser)             ?? .default
        multibandCompressor = try c.decodeIfPresent(MultibandCompressorConfig.self, forKey: .multibandCompressor) ?? .default
        compressor          = try c.decodeIfPresent(CompressorConfig.self,         forKey: .compressor)          ?? .default
        expander            = try c.decodeIfPresent(ExpanderConfig.self,           forKey: .expander)            ?? .default
        softClipper         = try c.decodeIfPresent(SoftClipperConfig.self,        forKey: .softClipper)         ?? .default
        limiter             = try c.decodeIfPresent(BrickwallLimiterConfig.self,   forKey: .limiter)             ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stereoWidener,       forKey: .stereoWidener)
        try c.encode(loudnessMatch,       forKey: .loudnessMatch)
        try c.encode(deEsser,             forKey: .deEsser)
        try c.encode(multibandCompressor, forKey: .multibandCompressor)
        try c.encode(compressor,          forKey: .compressor)
        try c.encode(expander,            forKey: .expander)
        try c.encode(softClipper,         forKey: .softClipper)
        try c.encode(limiter,             forKey: .limiter)
    }
}
