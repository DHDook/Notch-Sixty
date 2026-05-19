// DynamicsView.swift
// Controls for the dual-stage dynamics processor: soft clipper + brickwall limiter.

import SwiftUI

// MARK: - Main View

/// Panel for configuring the soft clipper and brickwall limiter.
/// Reads and writes through `EqualiserStore.dynamicsConfig` so all changes
/// are propagated atomically to the audio thread while running.
struct DynamicsView: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var gainReductionDB: Float = 0.0

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Dynamics")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Form {
                softClipperSection
                limiterSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 440)
        .onReceive(
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
        ) { _ in
            gainReductionDB = store.limiterGainReductionDB
        }
    }

    // MARK: - Soft Clipper Section

    private var softClipperSection: some View {
        Section {
            Toggle("Enabled", isOn: softClipperEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            DynamicsSliderRow(
                label: "Drive",
                value: softClipperDrive,
                range: -6.0...18.0,
                step: 0.5,
                formatValue: { String(format: "%+.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )

            DynamicsSliderRow(
                label: "Threshold",
                value: softClipperThreshold,
                range: -12.0...0.0,
                step: 0.1,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )

            DynamicsSliderRow(
                label: "Knee",
                value: softClipperKnee,
                range: 0.001...1.0,
                step: 0.001,
                formatValue: { String(format: "%.3f", $0) },
                leftEndLabel: "Soft",
                rightEndLabel: "Hard",
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )

        } header: {
            Text("Soft Clipper")
        } footer: {
            Text("Analogue-style wave-shaper. Gently rounds transient peaks before the brickwall limiter, reducing the harshness of subsequent limiting. Disabled by default.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Limiter Section

    private var limiterSection: some View {
        Section {
            Toggle("Enabled", isOn: limiterEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            DynamicsSliderRow(
                label: "Ceiling",
                value: limiterCeiling,
                range: -6.0...0.0,
                step: 0.1,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            DynamicsSliderRow(
                label: "Attack",
                value: limiterAttack,
                range: 0.0...10.0,
                step: 0.1,
                formatValue: { String(format: "%.1f ms", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            DynamicsSliderRow(
                label: "Release",
                value: limiterRelease,
                range: 5.0...250.0,
                step: 1.0,
                formatValue: { String(format: "%.0f ms", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            DynamicsSliderRow(
                label: "Look-ahead",
                value: limiterLookAhead,
                range: 0.5...10.0,
                step: 0.5,
                formatValue: { String(format: "%.1f ms", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            GainReductionMeterRow(gainReductionDB: gainReductionDB)
                .opacity(store.dynamicsConfig.limiter.isEnabled ? 1.0 : 0.4)

        } header: {
            Text("Brickwall Limiter")
        } footer: {
            Text("Look-ahead true peak limiter. Attack and look-ahead control how quickly the limiter responds to peaks. Guarantees the output cannot exceed the ceiling. Enabled by default as a clipping safeguard.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bindings

    private var softClipperEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.softClipper.isEnabled },
            set: { enabled in
                var sc = store.dynamicsConfig.softClipper
                sc.isEnabled = enabled
                store.updateSoftClipper(sc)
            }
        )
    }

    private var softClipperDrive: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.driveDB) },
            set: { val in
                var sc = store.dynamicsConfig.softClipper
                sc.driveDB = Float(val)
                store.updateSoftClipper(sc)
            }
        )
    }

    private var softClipperThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.thresholdDB) },
            set: { val in
                var sc = store.dynamicsConfig.softClipper
                sc.thresholdDB = Float(val)
                store.updateSoftClipper(sc)
            }
        )
    }

    private var softClipperKnee: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.kneeSmooth) },
            set: { val in
                var sc = store.dynamicsConfig.softClipper
                sc.kneeSmooth = Float(val)
                store.updateSoftClipper(sc)
            }
        )
    }

    private var limiterEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.limiter.isEnabled },
            set: { enabled in
                var lim = store.dynamicsConfig.limiter
                lim.isEnabled = enabled
                store.updateLimiter(lim)
            }
        )
    }

    private var limiterCeiling: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.ceilingDB) },
            set: { val in
                var lim = store.dynamicsConfig.limiter
                lim.ceilingDB = Float(val)
                store.updateLimiter(lim)
            }
        )
    }

    private var limiterAttack: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.attackMs) },
            set: { val in
                var lim = store.dynamicsConfig.limiter
                lim.attackMs = Float(val)
                store.updateLimiter(lim)
            }
        )
    }

    private var limiterRelease: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.releaseMs) },
            set: { val in
                var lim = store.dynamicsConfig.limiter
                lim.releaseMs = Float(val)
                store.updateLimiter(lim)
            }
        )
    }

    private var limiterLookAhead: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.lookAheadMs) },
            set: { val in
                var lim = store.dynamicsConfig.limiter
                lim.lookAheadMs = Float(val)
                store.updateLimiter(lim)
            }
        )
    }
}

// MARK: - Slider Row

/// A labelled slider row with an inline editable value field on the right.
/// Optional endpoint labels are rendered as Slider minimum/maximum value labels,
/// which places them flush with the track endpoints and avoids tick marks.
private struct DynamicsSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatValue: (Double) -> String
    var leftEndLabel: String? = nil
    var rightEndLabel: String? = nil
    var isDisabled: Bool = false

    @State private var textValue: String = ""
    @FocusState private var isFieldFocused: Bool

    /// Binding that snaps the slider value to the nearest step without passing
    /// `step:` to Slider itself, which would cause macOS to draw tick marks.
    private var snappedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { newVal in
                let rounded = (newVal / step).rounded() * step
                value = max(range.lowerBound, min(range.upperBound, rounded))
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)

            if leftEndLabel != nil || rightEndLabel != nil {
                Slider(value: snappedBinding, in: range) {
                    EmptyView()
                } minimumValueLabel: {
                    Text(leftEndLabel ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } maximumValueLabel: {
                    Text(rightEndLabel ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .controlSize(.small)
            } else {
                Slider(value: snappedBinding, in: range)
                    .controlSize(.small)
            }

            TextField("", text: $textValue)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 68, maxWidth: 68)
                .focused($isFieldFocused)
                .onSubmit { commitText() }
                .onChange(of: value) { _, newValue in
                    if !isFieldFocused {
                        textValue = formatValue(newValue)
                    }
                }
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused { commitText() }
                }
                .onAppear {
                    textValue = formatValue(value)
                }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isDisabled)
    }

    private func commitText() {
        if let parsed = parseValue(textValue) {
            let clamped = max(range.lowerBound, min(range.upperBound, parsed))
            value = clamped
        }
        textValue = formatValue(value)
    }

    private func parseValue(_ text: String) -> Double? {
        let normalised = text
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "dB", with: "")
            .replacingOccurrences(of: "ms", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(normalised)
    }
}

// MARK: - Gain Reduction Meter

/// Horizontal bar showing the brickwall limiter's current gain reduction.
/// Polls at 30 fps via the parent view's timer. Colour shifts from green → yellow → orange → red
/// as reduction depth increases.
private struct GainReductionMeterRow: View {
    let gainReductionDB: Float

    /// Magnitude of reduction (always ≥ 0; 0 = no reduction).
    private var reductionMagnitude: Double {
        Double(max(0.0, -gainReductionDB))
    }

    /// Full-scale range for the visual bar: 0 to −12 dB.
    private static let displayRangeDB: Double = 12.0

    private var fillFraction: Double {
        min(reductionMagnitude / Self.displayRangeDB, 1.0)
    }

    private var meterColor: Color {
        switch reductionMagnitude {
        case ..<1.0:  return .green
        case ..<3.0:  return .yellow
        case ..<6.0:  return .orange
        default:      return .red
        }
    }

    private var isActive: Bool { reductionMagnitude > 0.05 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Gain Reduction")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .leading)

                Spacer()

                Text(String(format: "%.1f dB", gainReductionDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? .primary : .secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.4))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(meterColor)
                        .frame(width: geo.size.width * fillFraction, height: 6)
                        .animation(.linear(duration: 1.0 / 30.0), value: fillFraction)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Inline Header Widget

/// Compact dynamics widget shown inline in the main window header, to the right of Gain Out.
/// Shows indicator dots and enable toggles for the soft clipper and brickwall limiter.
/// Dot colours: grey = disabled, green = enabled & idle, orange = enabled & active.
/// A waveform button below the Limiter toggle opens the full Dynamics panel.
struct DynamicsInlineView: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var clipperEngaged: Bool = false
    @State private var limiterEngaged: Bool = false
    @State private var showDynamicsPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dynamics")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(clipperDotColor)
                        .frame(width: 6, height: 6)
                    Toggle("Clipper", isOn: clipperEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize()
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(limiterDotColor)
                        .frame(width: 6, height: 6)
                    Toggle("Limiter", isOn: limiterEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize()
                }

                Button {
                    showDynamicsPanel.toggle()
                } label: {
                    Image(systemName: "waveform.path")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dynamics settings")
                .popover(isPresented: $showDynamicsPanel, arrowEdge: .trailing) {
                    DynamicsView()
                        .environmentObject(store)
                }
            }
        }
        .onReceive(
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
        ) { _ in
            clipperEngaged = store.clipperEngaged
            limiterEngaged = store.limiterGainReductionDB < -0.5
        }
    }

    // MARK: - Dot Colours

    private var clipperDotColor: Color {
        guard store.dynamicsConfig.softClipper.isEnabled else {
            return Color.secondary.opacity(0.3)
        }
        return clipperEngaged ? .orange : .green
    }

    private var limiterDotColor: Color {
        guard store.dynamicsConfig.limiter.isEnabled else {
            return Color.secondary.opacity(0.3)
        }
        return limiterEngaged ? .orange : .green
    }

    // MARK: - Bindings

    private var clipperEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.softClipper.isEnabled },
            set: { enabled in
                var sc = store.dynamicsConfig.softClipper
                sc.isEnabled = enabled
                store.updateSoftClipper(sc)
            }
        )
    }

    private var limiterEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.limiter.isEnabled },
            set: { enabled in
                var lim = store.dynamicsConfig.limiter
                lim.isEnabled = enabled
                store.updateLimiter(lim)
            }
        )
    }
}

// MARK: - Preview

#Preview("Dynamics Panel") {
    DynamicsView()
        .environmentObject(EqualiserStore())
}

#Preview("Dynamics Inline") {
    DynamicsInlineView()
        .environmentObject(EqualiserStore())
        .padding()
}
