// MultiChannelCorrectionPresetManager.swift
//
// Preset manager for multi-channel room correction measurements and corrections.
// Phase 7 of the Transfer Function Room Correction specification.

import Combine
import Foundation
import os.log

/// Error types for multi-channel correction preset operations.
enum MultiChannelCorrectionPresetError: LocalizedError {
    case directoryCreationFailed(Error)
    case encodingFailed(Error)
    case decodingFailed(Error)
    case writeFailed(Error)
    case readFailed(Error)
    case deleteFailed(Error)
    case renameFailed(Error)
    case presetNotFound(String)
    case presetAlreadyExists(String)
    case invalidPresetName

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let error):
            return "Failed to create multi-channel correction presets directory: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Failed to encode multi-channel correction preset: \(error.localizedDescription)"
        case .decodingFailed(let error):
            return "Failed to decode multi-channel correction preset: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Failed to write multi-channel correction preset file: \(error.localizedDescription)"
        case .readFailed(let error):
            return "Failed to read multi-channel correction preset file: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete multi-channel correction preset: \(error.localizedDescription)"
        case .renameFailed(let error):
            return "Failed to rename multi-channel correction preset: \(error.localizedDescription)"
        case .presetNotFound(let name):
            return "Multi-channel correction preset '\(name)' not found"
        case .presetAlreadyExists(let name):
            return "Multi-channel correction preset '\(name)' already exists"
        case .invalidPresetName:
            return "Invalid multi-channel correction preset name"
        }
    }
}

/// Manages multi-channel correction preset storage, loading, and saving.
@MainActor
final class MultiChannelCorrectionPresetManager: ObservableObject {
    // MARK: - Published Properties

    /// All loaded presets, sorted by name.
    @Published private(set) var presets: [MultiChannelCorrectionPreset] = []

    /// The currently selected preset name (nil if no preset is selected or if modified).
    @Published var selectedPresetName: String?

    /// Whether the current multi-channel correction settings have been modified from the loaded preset.
    @Published var isModified: Bool = false

    // MARK: - Private Properties

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "MultiChannelCorrectionPresetManager")
    private let storage: UserDefaults

    private enum Keys {
        static let selectedPreset = "multiChannelCorrection.selectedPreset"
    }

    /// The directory where multi-channel correction presets are stored.
    private var presetsDirectory: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // Fallback to Documents directory if Application Support is unavailable
            logger.warning("Application Support directory not found, falling back to Documents")
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Equaliser/MultiChannelCorrectionPresets", isDirectory: true)
        }
        return appSupport.appendingPathComponent("Equaliser/MultiChannelCorrectionPresets", isDirectory: true)
    }

    // MARK: - Initialization

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Restore selected preset name
        selectedPresetName = storage.string(forKey: Keys.selectedPreset)

        // Ensure directory exists and load presets
        ensureDirectoryExists()
        loadAllPresets()
    }

    // MARK: - Directory Management

    private func ensureDirectoryExists() {
        do {
            try fileManager.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
            logger.debug("Multi-channel correction presets directory ready: \(self.presetsDirectory.path)")
        } catch {
            logger.error("Failed to create multi-channel correction presets directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Loading Presets

    /// Loads all presets from the presets directory.
    func loadAllPresets() {
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: presetsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )

            let presetFiles = contents.filter { $0.pathExtension == MultiChannelCorrectionPreset.fileExtension }
            var loadedPresets: [MultiChannelCorrectionPreset] = []

            for fileURL in presetFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let preset = try decoder.decode(MultiChannelCorrectionPreset.self, from: data)
                    loadedPresets.append(preset)
                } catch {
                    logger.warning("Failed to load multi-channel correction preset from \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            presets = loadedPresets.sorted { $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending }
            logger.info("Loaded \(self.presets.count) multi-channel correction presets")
        } catch {
            logger.error("Failed to enumerate multi-channel correction presets directory: \(error.localizedDescription)")
            presets = []
        }
    }

    /// Returns the URL for a preset file.
    private func fileURL(for presetName: String) -> URL {
        let safeName = presetName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return presetsDirectory.appendingPathComponent("\(safeName).\(MultiChannelCorrectionPreset.fileExtension)")
    }

    // MARK: - CRUD Operations

    /// Saves a preset to disk.
    func savePreset(_ preset: MultiChannelCorrectionPreset) throws {
        guard !preset.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MultiChannelCorrectionPresetError.invalidPresetName
        }

        let fileURL = fileURL(for: preset.metadata.name)

        do {
            let data = try encoder.encode(preset)
            try data.write(to: fileURL, options: .atomic)
            logger.debug("Saved multi-channel correction preset: \(preset.metadata.name)")
        } catch let error as EncodingError {
            throw MultiChannelCorrectionPresetError.encodingFailed(error)
        } catch {
            throw MultiChannelCorrectionPresetError.writeFailed(error)
        }

        loadAllPresets()
    }

    /// Deletes a preset by name.
    func deletePreset(named name: String) throws {
        let fileURL = fileURL(for: name)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw MultiChannelCorrectionPresetError.presetNotFound(name)
        }

        do {
            try fileManager.removeItem(at: fileURL)
            logger.info("Deleted multi-channel correction preset: \(name)")
        } catch {
            throw MultiChannelCorrectionPresetError.deleteFailed(error)
        }

        // Clear selection if the deleted preset was selected
        if selectedPresetName == name {
            selectedPresetName = nil
            storage.removeObject(forKey: Keys.selectedPreset)
        }

        loadAllPresets()
    }

    /// Renames a preset.
    func renamePreset(from oldName: String, to newName: String) throws {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MultiChannelCorrectionPresetError.invalidPresetName
        }

        let oldFileURL = fileURL(for: oldName)
        let newFileURL = fileURL(for: newName)

        guard fileManager.fileExists(atPath: oldFileURL.path) else {
            throw MultiChannelCorrectionPresetError.presetNotFound(oldName)
        }

        guard !fileManager.fileExists(atPath: newFileURL.path) else {
            throw MultiChannelCorrectionPresetError.presetAlreadyExists(newName)
        }

        // Load the preset, rename it, and save with new name
        do {
            let data = try Data(contentsOf: oldFileURL)
            var preset = try decoder.decode(MultiChannelCorrectionPreset.self, from: data)
            preset = preset.renamed(to: newName)

            let newData = try encoder.encode(preset)
            try newData.write(to: newFileURL, options: .atomic)
            try fileManager.removeItem(at: oldFileURL)

            logger.info("Renamed multi-channel correction preset: \(oldName) -> \(newName)")
        } catch {
            throw MultiChannelCorrectionPresetError.renameFailed(error)
        }

        // Update selection if the renamed preset was selected
        if selectedPresetName == oldName {
            selectedPresetName = newName
            storage.set(newName, forKey: Keys.selectedPreset)
        }

        loadAllPresets()
    }

    /// Returns a preset by name.
    func preset(named name: String) -> MultiChannelCorrectionPreset? {
        presets.first { $0.metadata.name == name }
    }

    /// Checks if a preset with the given name exists.
    func presetExists(named name: String) -> Bool {
        presets.contains { $0.metadata.name == name }
    }

    /// Sets the selected preset and persists the selection.
    func selectPreset(named name: String?) {
        selectedPresetName = name
        isModified = false
        objectWillChange.send()
        if let name = name {
            storage.set(name, forKey: Keys.selectedPreset)
        } else {
            storage.removeObject(forKey: Keys.selectedPreset)
        }
    }

    /// Marks the current preset as modified.
    func markAsModified() {
        if selectedPresetName != nil {
            isModified = true
            objectWillChange.send()
        }
    }
}
