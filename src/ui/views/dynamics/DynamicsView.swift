// DynamicsView.swift
// Controls for the six-stage dynamics processor:
// De-Esser → Multiband Compressor → Compressor → Expander → Soft Clipper → Brickwall Limiter.

import AppKit
import SwiftUI

// MARK: - Main View

/// Panel for configuring the full dynamics chain.
/// Reads and writes through `EqualiserStore.dynamicsConfig` so all changes
/// are propagated atomically to the audio thread while running.
struct DynamicsView: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var gainReductionDB: Float = 0.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dynamics")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Form {
                deEsserSection
                multibandSection
                compressorSection
                expanderSection
                clipperSection
                limiterSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 550)
        .frame(minHeight: 900)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onReceive(
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
        ) { _ in
            gainReductionDB = store.limiterGainReductionDB
        }
    }

    // MARK: - De-Esser Section

    private var deEsserSection: some View {
        Section {
            Toggle("Enabled", isOn: deEsserEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Frequency",
                value: deEsserFreq,
                range: 2000.0...10000.0,
                step: 100.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.deEsser.isEnabled
            )

            DynamicsSliderRow(
                label: "Threshold",
                value: deEsserThreshold,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.deEsser.isEnabled
            )
        } header: {
            Text("De-Esser")
        }
    }

    // MARK: - Multiband Compressor Section

    private var multibandSection: some View {
        Section {
            Toggle("Enabled", isOn: mbEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Low / Mid",
                value: mbCrossLowMid,
                range: 40.0...250.0,
                step: 5.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Mid / High",
                value: mbCrossMidHigh,
                range: 1000.0...8000.0,
                step: 100.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Low Thresh",
                value: mbThreshLow,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Mid Thresh",
                value: mbThreshMid,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            DynamicsSliderRow(
                label: "High Thresh",
                value: mbThreshHigh,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )
        } header: {
            Text("Multiband Compressor")
        }
    }

    // MARK: - Compressor Section

    private var compressorSection: some View {
        Section {
            Toggle("Enabled", isOn: compressorEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Threshold",
                value: compressorThreshold,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Ratio",
                value: compressorRatio,
                range: 1.0...20.0,
                step: 0.1,
                formatValue: { String(format: "%.1f : 1", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Attack",
                value: compressorAttack,
                range: 0.1...100.0,
                step: 0.5,
                formatValue: { String(format: "%.1f ms", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Release",
                value: compressorRelease,
                range: 5.0...1000.0,
                step: 5.0,
                formatValue: { String(format: "%.0f ms", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Makeup",
                value: compressorMakeup,
                range: 0.0...24.0,
                step: 0.5,
                formatValue: { String(format: "%+.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )
        } header: {
            Text("Compressor")
        }
    }

    // MARK: - Expander Section

    private var expanderSection: some View {
        Section {
            Toggle("Enabled", isOn: expanderEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Threshold",
                value: expanderThreshold,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.expander.isEnabled
            )

            DynamicsSliderRow(
                label: "Ratio",
                value: expanderRatio,
                range: 1.0...4.0,
                step: 0.1,
                formatValue: { String(format: "%.1f : 1", $0) },
                isDisabled: !store.dynamicsConfig.expander.isEnabled
            )

            DynamicsSliderRow(
                label: "Range",
                value: expanderRange,
                range: -40.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.expander.isEnabled
            )
        } header: {
            Text("Expander")
        }
    }

    // MARK: - Clipper Section

    private var clipperSection: some View {
        Section {
            Toggle("Enabled", isOn: softClipperEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

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
            Text("Clipper")
        }
    }

    // MARK: - Limiter Section

    private var limiterSection: some View {
        Section {
            Toggle("Enabled", isOn: limiterEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

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
            Text("Limiter")
        }
    }

    // MARK: - De-Esser Bindings

    private var deEsserEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.deEsser.isEnabled },
            set: { v in var c = store.dynamicsConfig.deEsser; c.isEnabled = v; store.updateDeEsser(c) }
        )
    }

    private var deEsserFreq: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.deEsser.frequencyHz) },
            set: { v in var c = store.dynamicsConfig.deEsser; c.frequencyHz = Float(v); store.updateDeEsser(c) }
        )
    }

    private var deEsserThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.deEsser.thresholdDB) },
            set: { v in var c = store.dynamicsConfig.deEsser; c.thresholdDB = Float(v); store.updateDeEsser(c) }
        )
    }

    // MARK: - Multiband Bindings

    private var mbEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.isEnabled = v; store.updateMultibandCompressor(c) }
        )
    }

    private var mbCrossLowMid: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.crossLowMidHz) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.crossLowMidHz = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbCrossMidHigh: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.crossMidHighHz) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.crossMidHighHz = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbThreshLow: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.thresholdLowDB) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdLowDB = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbThreshMid: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.thresholdMidDB) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdMidDB = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbThreshHigh: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.thresholdHighDB) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdHighDB = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    // MARK: - Compressor Bindings

    private var compressorEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.compressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.compressor; c.isEnabled = v; store.updateCompressor(c) }
        )
    }

    private var compressorThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.thresholdDB) },
            set: { v in var c = store.dynamicsConfig.compressor; c.thresholdDB = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorRatio: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.ratio) },
            set: { v in var c = store.dynamicsConfig.compressor; c.ratio = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorAttack: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.attackMs) },
            set: { v in var c = store.dynamicsConfig.compressor; c.attackMs = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorRelease: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.releaseMs) },
            set: { v in var c = store.dynamicsConfig.compressor; c.releaseMs = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorMakeup: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.makeupGainDB) },
            set: { v in var c = store.dynamicsConfig.compressor; c.makeupGainDB = Float(v); store.updateCompressor(c) }
        )
    }

    // MARK: - Expander Bindings

    private var expanderEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.expander.isEnabled },
            set: { v in var c = store.dynamicsConfig.expander; c.isEnabled = v; store.updateExpander(c) }
        )
    }

    private var expanderThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.expander.thresholdDB) },
            set: { v in var c = store.dynamicsConfig.expander; c.thresholdDB = Float(v); store.updateExpander(c) }
        )
    }

    private var expanderRatio: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.expander.ratio) },
            set: { v in var c = store.dynamicsConfig.expander; c.ratio = Float(v); store.updateExpander(c) }
        )
    }

    private var expanderRange: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.expander.rangeDB) },
            set: { v in var c = store.dynamicsConfig.expander; c.rangeDB = Float(v); store.updateExpander(c) }
        )
    }

    // MARK: - Clipper Bindings

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

    // MARK: - Limiter Bindings

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
/// Optional endpoint labels are rendered as Slider minimum/maximum value labels.
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
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)

            if leftEndLabel != nil || rightEndLabel != nil {
                Slider(value: snappedBinding, in: range) {
                    EmptyView()
                } minimumValueLabel: {
                    Text(leftEndLabel ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text(rightEndLabel ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .layoutPriority(1)
            } else {
                Slider(value: snappedBinding, in: range)
                    .controlSize(.small)
                    .layoutPriority(1)
            }

            TextField("", text: $textValue)
                .font(.system(size: 13).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 80)
                .focused($isFieldFocused)
                .onSubmit {
                    commitText()
                    isFieldFocused = false
                }
                .onChange(of: value, initial: true) { _, newValue in
                    if !isFieldFocused {
                        textValue = formatValue(newValue)
                    }
                }
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused { commitText() }
                }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
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
            .replacingOccurrences(of: "Hz", with: "")
            .replacingOccurrences(of: ": 1", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(normalised)
    }
}

// MARK: - Gain Reduction Meter

/// Horizontal bar showing the brickwall limiter's current gain reduction.
/// Polls at 30 fps via the parent view's timer. Colour shifts green → yellow → orange → red.
private struct GainReductionMeterRow: View {
    let gainReductionDB: Float

    private var reductionMagnitude: Double {
        Double(max(0.0, -gainReductionDB))
    }

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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .leading)

                Spacer()

                Text(String(format: "%.1f dB", gainReductionDB))
                    .font(.system(size: 13).monospacedDigit())
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

/// Compact dynamics widget shown inline in the main window header.
/// Shows indicator dots and enable toggles for all six dynamics stages,
/// plus a tooltip `?` button that surfaces definitions for each processor.
struct DynamicsInlineView: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var clipperEngaged: Bool = false
    @State private var limiterEngaged: Bool = false
    @State private var showDynamicsPanel = false
    @State private var showDefinitions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Dynamics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Button {
                    showDefinitions.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDefinitions, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            definitionEntry(
                                title: "De-Esser",
                                body: "Tames harsh, high-frequency sibilance ('S' and 'T' sounds) by applying frequency-selective gain reduction around a tunable centre frequency, without altering the mid-range bite."
                            )
                            Divider()
                            definitionEntry(
                                title: "Multiband Compressor",
                                body: "Independently controls the dynamics of three separate frequency bands — Low, Mid, and High — using Linkwitz-Riley 4th-order crossovers. Prevents bass transients from choking the mix."
                            )
                            Divider()
                            definitionEntry(
                                title: "Compressor",
                                body: "Wideband feed-forward compressor that automatically balances dynamic range. Provides a cohesive, glued sound, adds transient punch, and accepts a makeup gain to compensate for gain reduction."
                            )
                            Divider()
                            definitionEntry(
                                title: "Expander",
                                body: "Downward dynamic-range expander. Widens perceived dynamics by attenuating signals that fall below the threshold, restoring life to over-compressed tracks and gating low-level noise."
                            )
                            Divider()
                            definitionEntry(
                                title: "Clipper",
                                body: "Analogue-style wave-shaper that gently rounds transient peaks before the limiter, reducing the harshness of subsequent limiting."
                            )
                            Divider()
                            definitionEntry(
                                title: "Limiter",
                                body: "Look-ahead true peak limiter. Guarantees the output cannot exceed the ceiling. Enabled by default as a clipping safeguard."
                            )
                        }
                        .padding(14)
                    }
                    .frame(width: 280, height: 380)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                inlineToggleRow(
                    label: "De-Esser",
                    dotColor: simpleDotColor(store.dynamicsConfig.deEsser.isEnabled),
                    binding: deEsserEnabled
                )
                inlineToggleRow(
                    label: "M-Band",
                    dotColor: simpleDotColor(store.dynamicsConfig.multibandCompressor.isEnabled),
                    binding: mbEnabled
                )
                inlineToggleRow(
                    label: "Comp.",
                    dotColor: simpleDotColor(store.dynamicsConfig.compressor.isEnabled),
                    binding: compressorEnabled
                )
                inlineToggleRow(
                    label: "Expander",
                    dotColor: simpleDotColor(store.dynamicsConfig.expander.isEnabled),
                    binding: expanderEnabled
                )
                inlineToggleRow(
                    label: "Clipper",
                    dotColor: clipperDotColor,
                    binding: clipperEnabled
                )
                inlineToggleRow(
                    label: "Limiter",
                    dotColor: limiterDotColor,
                    binding: limiterEnabled
                )

                Button {
                    showDynamicsPanel.toggle()
                } label: {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 20))
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

    // MARK: - Helper Views

    @ViewBuilder
    private func inlineToggleRow(
        label: String,
        dotColor: Color,
        binding: Binding<Bool>
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func definitionEntry(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Dot Colours

    private func simpleDotColor(_ enabled: Bool) -> Color {
        enabled ? .green : Color.secondary.opacity(0.3)
    }

    private var clipperDotColor: Color {
        guard store.dynamicsConfig.softClipper.isEnabled else { return Color.secondary.opacity(0.3) }
        return clipperEngaged ? .orange : .green
    }

    private var limiterDotColor: Color {
        guard store.dynamicsConfig.limiter.isEnabled else { return Color.secondary.opacity(0.3) }
        return limiterEngaged ? .orange : .green
    }

    // MARK: - Bindings

    private var deEsserEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.deEsser.isEnabled },
            set: { v in var c = store.dynamicsConfig.deEsser; c.isEnabled = v; store.updateDeEsser(c) }
        )
    }

    private var mbEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.isEnabled = v; store.updateMultibandCompressor(c) }
        )
    }

    private var compressorEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.compressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.compressor; c.isEnabled = v; store.updateCompressor(c) }
        )
    }

    private var expanderEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.expander.isEnabled },
            set: { v in var c = store.dynamicsConfig.expander; c.isEnabled = v; store.updateExpander(c) }
        )
    }

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
