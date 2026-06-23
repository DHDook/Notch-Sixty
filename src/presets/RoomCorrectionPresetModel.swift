import Foundation

/// Metadata for a room correction preset (name, timestamps).
struct RoomCorrectionPresetMetadata: Codable, Sendable {
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    init(name: String, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// Settings snapshot for a room correction preset.
struct RoomCorrectionPresetSettings: Codable, Sendable {
    // Raw measurement state — enables re-fitting later without re-measuring.
    var targetCurveName: String
    var customTargetCurve: [TargetCurvePoint]?
    var seatMeasurements: [EqualiserStore.SeatMeasurement]
    var measuredResponse: [TargetCurvePoint]
    var micCalibration: MicCalibration?

    // Applied/derived result — enables instant, deterministic reload.
    var appliedBands: [PresetBand]
    var roomCorrectionEnabled: Bool

    // FIR correction state, if the user upgraded from IIR to FIR (optional).
    var firTapCount: Int?
    var firCorrectionApplied: Bool
}

/// Helper struct for frequency/gain curve points.
struct TargetCurvePoint: Codable, Sendable {
    let frequency: Double
    let gainDB: Double
}

/// A complete room correction preset with version, metadata, and settings.
struct RoomCorrectionPreset: Codable, Sendable, Identifiable {
    static let fileExtension = "roomcorrectionpreset"
    static let currentVersion = 1

    var version: Int = RoomCorrectionPreset.currentVersion
    var metadata: RoomCorrectionPresetMetadata
    var settings: RoomCorrectionPresetSettings

    var id: String { metadata.name }
    var filename: String { "\(metadata.name).\(Self.fileExtension)" }

    init(
        version: Int = RoomCorrectionPreset.currentVersion,
        metadata: RoomCorrectionPresetMetadata,
        settings: RoomCorrectionPresetSettings
    ) {
        self.version = version
        self.metadata = metadata
        self.settings = settings
    }

    /// Creates a copy of the preset with an updated modification timestamp.
    func withUpdatedTimestamp() -> RoomCorrectionPreset {
        var copy = self
        copy.metadata.modifiedAt = Date()
        return copy
    }

    /// Creates a copy of the preset with a new name.
    func renamed(to newName: String) -> RoomCorrectionPreset {
        var copy = self
        copy.metadata.name = newName
        copy.metadata.modifiedAt = Date()
        return copy
    }
}
