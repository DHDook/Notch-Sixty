// MultiChannelCorrectionPresetModel.swift
//
// Preset model for multi-channel room correction measurements and corrections.
// Phase 7 of the Transfer Function Room Correction specification.

import Foundation

/// Metadata for a multi-channel correction preset (name, timestamps).
struct MultiChannelCorrectionPresetMetadata: Codable, Sendable {
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    init(name: String, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// Settings snapshot for a multi-channel correction preset.
struct MultiChannelCorrectionPresetSettings: Codable, Sendable {
    /// Per-channel transfer function measurements.
    var channels: [ChannelTransferFunctionData]
    /// Applied corrections per channel (channelIndex -> correction result).
    var appliedCorrections: [Int: ChannelCorrectionResult]
    /// Combined multi-driver measurement, if available.
    var combinedMeasurement: CombinedMeasurementResult?
}

/// A complete multi-channel correction preset with version, metadata, and settings.
struct MultiChannelCorrectionPreset: Codable, Sendable, Identifiable {
    static let fileExtension = "mcpreset"
    static let currentVersion = 1

    var version: Int = MultiChannelCorrectionPreset.currentVersion
    var metadata: MultiChannelCorrectionPresetMetadata
    var settings: MultiChannelCorrectionPresetSettings

    var id: String { metadata.name }
    var filename: String { "\(metadata.name).\(Self.fileExtension)" }

    init(
        version: Int = MultiChannelCorrectionPreset.currentVersion,
        metadata: MultiChannelCorrectionPresetMetadata,
        settings: MultiChannelCorrectionPresetSettings
    ) {
        self.version = version
        self.metadata = metadata
        self.settings = settings
    }

    /// Creates a copy of the preset with an updated modification timestamp.
    func withUpdatedTimestamp() -> MultiChannelCorrectionPreset {
        var copy = self
        copy.metadata.modifiedAt = Date()
        return copy
    }

    /// Creates a copy of the preset with a new name.
    func renamed(to newName: String) -> MultiChannelCorrectionPreset {
        var copy = self
        copy.metadata.name = newName
        copy.metadata.modifiedAt = Date()
        return copy
    }
}
