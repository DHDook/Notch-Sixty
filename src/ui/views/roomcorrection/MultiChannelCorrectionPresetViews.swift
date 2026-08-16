import AppKit
import Combine
import SwiftUI

// MARK: - Multi-Channel Correction Preset Picker

/// A picker for selecting multi-channel correction presets, with modified indicator.
struct MultiChannelCorrectionPresetPicker: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                MultiChannelCorrectionPresetMenuContentView()
            } label: {
                MultiChannelCorrectionPresetMenuLabelView()
            }
            MultiChannelCorrectionModifiedIndicator()
        }
    }
}

// MARK: - Multi-Channel Correction Modified Indicator

/// A small indicator showing that the current multi-channel correction preset has been modified.
struct MultiChannelCorrectionModifiedIndicator: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        if store.multiChannelCorrectionPresetManager.isModified {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Multi-Channel Correction Preset Menu Helpers

struct MultiChannelCorrectionPresetMenuLabelView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        Text(store.multiChannelCorrectionPresetManager.selectedPresetName ?? "No Preset")
            .lineLimit(1)
    }
}

struct MultiChannelCorrectionPresetMenuContentView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        if store.multiChannelCorrectionPresetManager.presets.isEmpty {
            Text("No saved presets yet — run a multi-channel measurement and apply corrections first")
                .foregroundStyle(.secondary)
        } else {
            presetSection(title: "Saved Presets", presets: store.multiChannelCorrectionPresetManager.presets)
        }

        Divider()
    }

    @ViewBuilder
    private func presetSection(title: String, presets: [MultiChannelCorrectionPreset]) -> some View {
        Section(title) {
            ForEach(presets) { preset in
                presetRow(for: preset)
            }
        }
    }

    @ViewBuilder
    private func presetRow(for preset: MultiChannelCorrectionPreset) -> some View {
        Button {
            store.loadMultiChannelCorrectionPreset(preset)
        } label: {
            HStack {
                Text(preset.metadata.name)
                if preset.metadata.name == store.multiChannelCorrectionPresetManager.selectedPresetName {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

// MARK: - Save Multi-Channel Correction Preset Sheet

/// A sheet for saving a new multi-channel correction preset or renaming an existing one.
struct SaveMultiChannelCorrectionPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: EqualiserStore

    @State private var presetName: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Multi-Channel Correction Preset")
                .font(.headline)

            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    savePreset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func savePreset() {
        do {
            _ = try store.saveCurrentAsMultiChannelCorrectionPreset(named: presetName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Delete Multi-Channel Correction Preset Sheet

/// A sheet for confirming deletion of a multi-channel correction preset.
struct DeleteMultiChannelCorrectionPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: EqualiserStore

    let presetName: String

    var body: some View {
        VStack(spacing: 16) {
            Text("Delete Preset")
                .font(.headline)

            Text("Are you sure you want to delete '\(presetName)'? This action cannot be undone.")
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Delete") {
                    deletePreset()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func deletePreset() {
        do {
            try store.multiChannelCorrectionPresetManager.deletePreset(named: presetName)
            dismiss()
        } catch {
            // Error handling - could show alert
            dismiss()
        }
    }
}

// MARK: - Rename Multi-Channel Correction Preset Sheet

/// A sheet for renaming a multi-channel correction preset.
struct RenameMultiChannelCorrectionPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: EqualiserStore

    let oldName: String
    @State private var newName: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Preset")
                .font(.headline)

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Rename") {
                    renamePreset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            newName = oldName
        }
    }

    private func renamePreset() {
        do {
            try store.multiChannelCorrectionPresetManager.renamePreset(from: oldName, to: newName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
