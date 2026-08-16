import SwiftUI

// MARK: - Resonance Detection View

/// A view for detecting and managing diaphragm resonance candidates for a specific channel.
struct ResonanceDetectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: EqualiserStore

    let channelIndex: Int

    @State private var searchRangeMode: SearchRangeMode = .fullRange
    @State private var minimumProminenceDB: Double = 3.0
    @State private var hasDetected = false

    enum SearchRangeMode: String, CaseIterable {
        case wooferBreakup = "Woofer (800-5000 Hz)"
        case tweeterBreakup = "Tweeter (5000-20000 Hz)"
        case fullRange = "Full Range"

        var range: (Double, Double) {
            switch self {
            case .wooferBreakup: return (800.0, 5000.0)
            case .tweeterBreakup: return (5000.0, 20000.0)
            case .fullRange: return (200.0, 20000.0)
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Resonance Detection - Channel \(channelIndex)")
                .font(.headline)

            // Detection controls
            VStack(alignment: .leading, spacing: 12) {
                Text("Search Range")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Search Range", selection: $searchRangeMode) {
                    ForEach(SearchRangeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Minimum Prominence: \(String(format: "%.1f", minimumProminenceDB)) dB")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Slider(value: $minimumProminenceDB, in: 1.0...10.0, step: 0.5)
                }

                Button("Detect Resonances") {
                    detectResonances()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Divider()

            // Candidates list
            if hasDetected {
                if let candidates = store.resonanceCandidates[channelIndex], !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detected Resonances")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 8) {
                            ForEach(candidates) { candidate in
                                CandidateRow(
                                    candidate: candidate,
                                    channelIndex: channelIndex
                                )
                            }
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                        Text("No resonances detected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Run detection to find resonances")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            Divider()

            // Close button
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 400, height: 500)
    }

    private func detectResonances() {
        let params = DiaphragmResonanceDetector.DetectionParameters(
            searchRangeHz: searchRangeMode.range,
            minimumProminenceDB: minimumProminenceDB,
            minimumQ: 3.0,
            maxCandidates: 5,
            backgroundSmoothingOctaves: 1.0 / 24.0
        )
        store.detectResonances(for: channelIndex, params: params)
        hasDetected = true
    }
}

// MARK: - Candidate Row

private struct CandidateRow: View {
    @EnvironmentObject var store: EqualiserStore
    let candidate: DiaphragmResonanceDetector.ResonanceCandidate
    let channelIndex: Int

    var body: some View {
        HStack(spacing: 12) {
            // Confidence indicator
            confidenceIndicator

            VStack(alignment: .leading, spacing: 4) {
                Text(formatFrequency(candidate.frequencyHz))
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Text("Prominence: \(String(format: "%.1f", candidate.prominenceDB)) dB")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Q: \(String(format: "%.1f", candidate.estimatedQ))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Apply Notch") {
                store.appendBandToOutputChannel(index: channelIndex, band: candidate.suggestedNotch)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private var confidenceIndicator: some View {
        Circle()
            .fill(confidenceColor)
            .frame(width: 12, height: 12)
            .help("Confidence: \(Int(candidate.confidence * 100))%")
    }

    private var confidenceColor: Color {
        if candidate.confidence >= 0.7 {
            return .green
        } else if candidate.confidence >= 0.5 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatFrequency(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1f kHz", hz / 1000)
        } else {
            return String(format: "%.0f Hz", hz)
        }
    }
}

#Preview {
    ResonanceDetectionView(channelIndex: 0)
        .environmentObject(EqualiserStore())
}
