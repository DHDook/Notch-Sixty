import AppKit
import Combine
import SwiftUI

// MARK: - Room Correction Preset Picker

/// A picker for selecting room correction presets, with modified indicator.
struct RoomCorrectionPresetPicker: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                RoomCorrectionPresetMenuContentView()
            } label: {
                RoomCorrectionPresetMenuLabelView()
            }
            RoomCorrectionModifiedIndicator()
        }
    }
}

// MARK: - Room Correction Modified Indicator

/// A small indicator showing that the current room correction preset has been modified.
struct RoomCorrectionModifiedIndicator: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        if store.roomCorrectionPresetManager.isModified {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Room Correction Preset Menu Helpers

struct RoomCorrectionPresetMenuLabelView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        Text(store.roomCorrectionPresetManager.selectedPresetName ?? "No Profile")
            .lineLimit(1)
    }
}

struct RoomCorrectionPresetMenuContentView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        if store.roomCorrectionPresetManager.presets.isEmpty {
            Text("No saved profiles yet — run a measurement and apply correction first")
                .foregroundStyle(.secondary)
        } else {
            presetSection(title: "Saved Profiles", presets: store.roomCorrectionPresetManager.presets)
        }

        Divider()
    }

    @ViewBuilder
    private func presetSection(title: String, presets: [RoomCorrectionPreset]) -> some View {
        Section(title) {
            ForEach(presets) { preset in
                presetRow(for: preset)
            }
        }
    }

    @ViewBuilder
    private func presetRow(for preset: RoomCorrectionPreset) -> some View {
        Button {
            store.loadRoomCorrectionPreset(preset)
        } label: {
            HStack {
                Text(preset.metadata.name)
                if preset.metadata.name == store.roomCorrectionPresetManager.selectedPresetName {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

// MARK: - Save Room Correction Preset Sheet

/// A sheet for saving a new room correction preset or renaming an existing one.
struct SaveRoomCorrectionPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: EqualiserStore

    @State private var presetName: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Room Correction Profile")
                .font(.headline)

            TextField("Profile name", text: $presetName)
                .textFieldStyle(.roundedBorder)

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    savePreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            errorMessage = "Please enter a name"
            return
        }

        do {
            _ = try store.saveCurrentAsRoomCorrectionPreset(named: name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Room Correction Preset Toolbar

/// Toolbar for room correction preset management in RoomCalibrationTab.
struct RoomCorrectionPresetToolbar: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var showingSaveSheet = false
    @State private var showingRenameSheet = false
    @State private var renameTarget: String?

    var body: some View {
        HStack(spacing: 8) {
            RoomCorrectionPresetPicker()

            Button {
                showingSaveSheet = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save current calibration as profile")

            Button {
                store.createNewRoomCorrectionPreset()
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .help("Create new profile (clears current calibration)")

            Menu {
                if let selectedName = store.roomCorrectionPresetManager.selectedPresetName {
                    Button("Save") {
                        do {
                            try store.updateCurrentRoomCorrectionPreset()
                        } catch {
                            // Handle error - could show alert
                        }
                    }

                    Button("Save As…") {
                        showingSaveSheet = true
                    }

                    Button("Rename…") {
                        renameTarget = selectedName
                        showingRenameSheet = true
                    }

                    Divider()

                    Button(role: .destructive) {
                        do {
                            try store.roomCorrectionPresetManager.deletePreset(named: selectedName)
                        } catch {
                            // Handle error - could show alert
                        }
                    } label: {
                        Text("Delete")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .disabled(store.roomCorrectionPresetManager.selectedPresetName == nil)
        }
        .sheet(isPresented: $showingSaveSheet) {
            SaveRoomCorrectionPresetSheet()
        }
        .sheet(isPresented: $showingRenameSheet) {
            if let target = renameTarget {
                RenameRoomCorrectionPresetSheet(targetName: target)
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - Rename Room Correction Preset Sheet

struct RenameRoomCorrectionPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: EqualiserStore

    let targetName: String
    @State private var newName: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Profile")
                .font(.headline)

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    renamePreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            newName = targetName
        }
    }

    private func renamePreset() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            errorMessage = "Please enter a name"
            return
        }

        do {
            try store.roomCorrectionPresetManager.renamePreset(from: targetName, to: name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
