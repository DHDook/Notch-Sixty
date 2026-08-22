// LatencyReadoutView.swift
// Pipeline latency readout (Part 9.3)
//
// Displays the total algorithmic latency of all currently-enabled stages.

import SwiftUI

struct LatencyReadoutView: View {
    let totalLatencyMs: Double
    let alignmentDelayMs: Double
    let sampleRate: Double

    private var sampleRateText: String {
        sampleRate >= 1000
            ? String(format: "%.0f kHz", sampleRate / 1000)
            : String(format: "%.0f Hz", sampleRate)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latency")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(String(format: "%.1f", totalLatencyMs)) ms")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sample Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sampleRateText)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            if alignmentDelayMs > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alignment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", alignmentDelayMs)) ms")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
