import Combine
import Foundation
import os.log

/// Error types for room correction preset operations.
enum RoomCorrectionPresetError: LocalizedError {
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
            return "Failed to create room correction presets directory: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Failed to encode room correction preset: \(error.localizedDescription)"
        case .decodingFailed(let error):
            return "Failed to decode room correction preset: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Failed to write room correction preset file: \(error.localizedDescription)"
        case .readFailed(let error):
            return "Failed to read room correction preset file: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete room correction preset: \(error.localizedDescription)"
        case .renameFailed(let error):
            return "Failed to rename room correction preset: \(error.localizedDescription)"
        case .presetNotFound(let name):
            return "Room correction preset '\(name)' not found"
        case .presetAlreadyExists(let name):
            return "Room correction preset '\(name)' already exists"
        case .invalidPresetName:
            return "Invalid room correction preset name"
        }
    }
}

/// Manages room correction preset storage, loading, and saving.
@MainActor
final class RoomCorrectionPresetManager: ObservableObject {
    // MARK: - Published Properties

    /// All loaded presets, sorted by name.
    @Published private(set) var presets: [RoomCorrectionPreset] = []

    /// The currently selected preset name (nil if no preset is selected or if modified).
    @Published var selectedPresetName: String?

    /// Whether the current room correction settings have been modified from the loaded preset.
    @Published var isModified: Bool = false

    // MARK: - Private Properties

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "RoomCorrectionPresetManager")
    private let storage: UserDefaults

    private enum Keys {
        static let selectedPreset = "roomCorrection.selectedPreset"
    }

    /// The directory where room correction presets are stored.
    private var presetsDirectory: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // Fallback to Documents directory if Application Support is unavailable
            logger.warning("Application Support directory not found, falling back to Documents")
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Equaliser/RoomCorrectionPresets", isDirectory: true)
        }
        return appSupport.appendingPathComponent("Equaliser/RoomCorrectionPresets", isDirectory: true)
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
            logger.debug("Room correction presets directory ready: \(self.presetsDirectory.path)")
        } catch {
            logger.error("Failed to create room correction presets directory: \(error.localizedDescription)")
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

            let presetFiles = contents.filter { $0.pathExtension == RoomCorrectionPreset.fileExtension }
            var loadedPresets: [RoomCorrectionPreset] = []

            for fileURL in presetFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let preset = try decoder.decode(RoomCorrectionPreset.self, from: data)
                    loadedPresets.append(preset)
                } catch {
                    logger.warning("Failed to load room correction preset from \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            presets = loadedPresets.sorted { $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending }
            logger.info("Loaded \(self.presets.count) room correction presets")
        } catch {
            logger.error("Failed to enumerate room correction presets directory: \(error.localizedDescription)")
            presets = []
        }
    }

    /// Returns the URL for a preset file.
    private func fileURL(for presetName: String) -> URL {
        let safeName = presetName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return presetsDirectory.appendingPathComponent("\(safeName).\(RoomCorrectionPreset.fileExtension)")
    }

    // MARK: - CRUD Operations

    /// Saves a preset to disk.
    func savePreset(_ preset: RoomCorrectionPreset) throws {
        guard !preset.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomCorrectionPresetError.invalidPresetName
        }

        let fileURL = fileURL(for: preset.metadata.name)

        do {
            let data = try encoder.encode(preset)
            try data.write(to: fileURL, options: .atomic)
            logger.debug("Saved room correction preset: \(preset.metadata.name)")
        } catch let error as EncodingError {
            throw RoomCorrectionPresetError.encodingFailed(error)
        } catch {
            throw RoomCorrectionPresetError.writeFailed(error)
        }

        loadAllPresets()
    }

    /// Deletes a preset by name.
    func deletePreset(named name: String) throws {
        let fileURL = fileURL(for: name)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw RoomCorrectionPresetError.presetNotFound(name)
        }

        do {
            try fileManager.removeItem(at: fileURL)
            logger.info("Deleted room correction preset: \(name)")
        } catch {
            throw RoomCorrectionPresetError.deleteFailed(error)
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
            throw RoomCorrectionPresetError.invalidPresetName
        }

        let oldFileURL = fileURL(for: oldName)
        let newFileURL = fileURL(for: newName)

        guard fileManager.fileExists(atPath: oldFileURL.path) else {
            throw RoomCorrectionPresetError.presetNotFound(oldName)
        }

        guard !fileManager.fileExists(atPath: newFileURL.path) else {
            throw RoomCorrectionPresetError.presetAlreadyExists(newName)
        }

        // Load the preset, rename it, and save with new name
        do {
            let data = try Data(contentsOf: oldFileURL)
            var preset = try decoder.decode(RoomCorrectionPreset.self, from: data)
            preset = preset.renamed(to: newName)

            let newData = try encoder.encode(preset)
            try newData.write(to: newFileURL, options: .atomic)
            try fileManager.removeItem(at: oldFileURL)

            logger.info("Renamed room correction preset: \(oldName) -> \(newName)")
        } catch {
            throw RoomCorrectionPresetError.renameFailed(error)
        }

        // Update selection if the renamed preset was selected
        if selectedPresetName == oldName {
            selectedPresetName = newName
            storage.set(newName, forKey: Keys.selectedPreset)
        }

        loadAllPresets()
    }

    /// Returns a preset by name.
    func preset(named name: String) -> RoomCorrectionPreset? {
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
