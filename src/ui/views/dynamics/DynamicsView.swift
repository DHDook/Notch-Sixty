// DynamicsView.swift
// Controls for the full dynamics processor chain:
// Stereo Widener → LUFS Loudness Match → De-Esser → Multiband Compressor
// → Compressor → Expander → Soft Clipper → Brickwall Limiter.

import AppKit
import SwiftUI

// MARK: - Main View

/// Panel for configuring the full dynamics chain.
/// Reads and writes through `EqualiserStore.dynamicsConfig` so all changes
/// are propagated atomically to the audio thread while running.
struct DynamicsView: View {
    @EnvironmentObject var store: EqualiserStore

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
                stereoWidenerSection
                loudnessMatchSection
                deEsserSection
                multibandSection
                compressorSection
                expanderSection
                clipperSection
                limiterSection
                stereoMatrixSection
                spectralEnhancementSection
                dynamicsRefinementSection
                systemUtilitiesSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 550)
        .frame(minHeight: 1000)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: - Stereo Widener Section

    private var stereoWidenerSection: some View {
        Section {
            Toggle("Enabled", isOn: stereoWidenerEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Low Width",
                value: widthLow,
                range: 0.0...1.0,
                step: 0.05,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Mono",
                rightEndLabel: "Stereo",
                isDisabled: !store.dynamicsConfig.stereoWidener.isEnabled
            )

            DynamicsSliderRow(
                label: "Mid Width",
                value: widthMid,
                range: 1.0...2.0,
                step: 0.05,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Narrow",
                rightEndLabel: "Wide",
                isDisabled: !store.dynamicsConfig.stereoWidener.isEnabled
            )

            DynamicsSliderRow(
                label: "High Width",
                value: widthHigh,
                range: 1.0...2.0,
                step: 0.05,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Narrow",
                rightEndLabel: "Wide",
                isDisabled: !store.dynamicsConfig.stereoWidener.isEnabled
            )
        } header: {
            Text("Stereo Widener")
        } footer: {
            Text("Low band (< 200 Hz) defaults to mono for tight bass. Mid and High expand stereo width.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Loudness Match Section

    private var loudnessMatchSection: some View {
        Section {
            Toggle("Enabled", isOn: loudnessMatchEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Target",
                value: targetLUFS,
                range: -24.0...(-10.0),
                step: 0.5,
                formatValue: { String(format: "%.1f LUFS", $0) },
                isDisabled: !store.dynamicsConfig.loudnessMatch.isEnabled
            )
        } header: {
            Text("LUFS Loudness Match")
        } footer: {
            Text("Continuously measures 3-second K-weighted loudness and applies a smooth gain correction to hit the target.")
                .font(.caption)
                .foregroundStyle(.tertiary)
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

            HStack(spacing: 8) {
                Text("LM Slope")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: mbSlopeLowMid) {
                    Text("Gentle (24 dB/oct)").tag(CrossoverSlope.gentle)
                    Text("Steep (48 dB/oct)").tag(CrossoverSlope.steep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(!store.dynamicsConfig.multibandCompressor.isEnabled)
            .opacity(!store.dynamicsConfig.multibandCompressor.isEnabled ? 0.4 : 1.0)

            DynamicsSliderRow(
                label: "Mid / High",
                value: mbCrossMidHigh,
                range: 1000.0...8000.0,
                step: 100.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            HStack(spacing: 8) {
                Text("MH Slope")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: mbSlopeMidHigh) {
                    Text("Gentle (24 dB/oct)").tag(CrossoverSlope.gentle)
                    Text("Steep (48 dB/oct)").tag(CrossoverSlope.steep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(!store.dynamicsConfig.multibandCompressor.isEnabled)
            .opacity(!store.dynamicsConfig.multibandCompressor.isEnabled ? 0.4 : 1.0)

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
        } footer: {
            Text("Gentle = LR4 (24 dB/oct). Steep = LR8 (48 dB/oct). Fixed ratio 4:1 with 6 dB soft-knee per band.")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
                label: "Knee",
                value: compressorKneeWidth,
                range: 0.0...20.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                leftEndLabel: "Hard",
                rightEndLabel: "Soft",
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

        } header: {
            Text("Limiter")
        }
    }

    // MARK: - Stereo Widener Bindings

    private var stereoWidenerEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.stereoWidener.isEnabled },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.isEnabled = v; store.updateStereoWidener(c) }
        )
    }

    private var widthLow: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.stereoWidener.widthFactorLow) },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorLow = Float(v); store.updateStereoWidener(c) }
        )
    }

    private var widthMid: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.stereoWidener.widthFactorMid) },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorMid = Float(v); store.updateStereoWidener(c) }
        )
    }

    private var widthHigh: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.stereoWidener.widthFactorHigh) },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorHigh = Float(v); store.updateStereoWidener(c) }
        )
    }

    // MARK: - Loudness Match Bindings

    private var loudnessMatchEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.loudnessMatch.isEnabled },
            set: { v in var c = store.dynamicsConfig.loudnessMatch; c.isEnabled = v; store.updateLoudnessMatch(c) }
        )
    }

    private var targetLUFS: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.loudnessMatch.targetLoudnessLUFS) },
            set: { v in var c = store.dynamicsConfig.loudnessMatch; c.targetLoudnessLUFS = Float(v); store.updateLoudnessMatch(c) }
        )
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

    private var mbSlopeLowMid: Binding<CrossoverSlope> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.slopeLowMid },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.slopeLowMid = v; store.updateMultibandCompressor(c) }
        )
    }

    private var mbSlopeMidHigh: Binding<CrossoverSlope> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.slopeMidHigh },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.slopeMidHigh = v; store.updateMultibandCompressor(c) }
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

    private var compressorKneeWidth: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.kneeWidthDB) },
            set: { v in var c = store.dynamicsConfig.compressor; c.kneeWidthDB = Float(v); store.updateCompressor(c) }
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
            set: { enabled in var sc = store.dynamicsConfig.softClipper; sc.isEnabled = enabled; store.updateSoftClipper(sc) }
        )
    }

    private var softClipperDrive: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.driveDB) },
            set: { val in var sc = store.dynamicsConfig.softClipper; sc.driveDB = Float(val); store.updateSoftClipper(sc) }
        )
    }

    private var softClipperThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.thresholdDB) },
            set: { val in var sc = store.dynamicsConfig.softClipper; sc.thresholdDB = Float(val); store.updateSoftClipper(sc) }
        )
    }

    private var softClipperKnee: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.kneeSmooth) },
            set: { val in var sc = store.dynamicsConfig.softClipper; sc.kneeSmooth = Float(val); store.updateSoftClipper(sc) }
        )
    }

    // MARK: - Limiter Bindings

    private var limiterEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.limiter.isEnabled },
            set: { enabled in var lim = store.dynamicsConfig.limiter; lim.isEnabled = enabled; store.updateLimiter(lim) }
        )
    }

    private var limiterCeiling: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.ceilingDB) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.ceilingDB = Float(val); store.updateLimiter(lim) }
        )
    }

    private var limiterAttack: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.attackMs) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.attackMs = Float(val); store.updateLimiter(lim) }
        )
    }

    private var limiterRelease: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.releaseMs) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.releaseMs = Float(val); store.updateLimiter(lim) }
        )
    }

    private var limiterLookAhead: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.lookAheadMs) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.lookAheadMs = Float(val); store.updateLimiter(lim) }
        )
    }

    // MARK: - Stereo Matrix Section

    private var stereoMatrixSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Stereo Mode")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: stereoModeBinding) {
                    Text("Stereo").tag(StereoModeSelection.stereo)
                    Text("Wide Mono").tag(StereoModeSelection.wideMono)
                    Text("True Mono").tag(StereoModeSelection.trueMono)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("DC Offset Filter", isOn: dcOffsetEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Balance",
                value: balanceBinding,
                range: -1.0...1.0,
                step: 0.01,
                formatValue: { val in
                    if val < -0.01 { return String(format: "%.0f%% L", -val * 100) }
                    if val >  0.01 { return String(format: "%.0f%% R",  val * 100) }
                    return "Centre"
                },
                leftEndLabel: "L",
                rightEndLabel: "R"
            )

            DynamicsSliderRow(
                label: "L/R Delay",
                value: timeDelayBinding,
                range: 0.0...20.0,
                step: 0.1,
                formatValue: { String(format: "%.1f ms", $0) }
            )
        } header: {
            Text("Stereo Matrix")
        } footer: {
            Text("Stereo Mode folds the signal before all other stages. Balance and L/R Delay are applied after the dynamics chain.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Spectral Enhancement Section

    private var spectralEnhancementSection: some View {
        Section {
            Toggle("Loudness Contouring", isOn: loudnessContourBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("De-Harsh Filter", isOn: deharshEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Tilt Amount",
                value: deharshTiltBinding,
                range: -6.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%+.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.advanced.deharshFilterEnabled
            )
        } header: {
            Text("Spectral Enhancement")
        } footer: {
            Text("Loudness Contouring applies a gentle Fletcher-Munson compensation curve. De-Harsh attenuates frequencies above 3.5 kHz after the limiter.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Dynamics Refinement Section

    private var dynamicsRefinementSection: some View {
        Section {
            Toggle("Dialogue Gate (LUFS)", isOn: dialogueGateBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("De-Esser: Dynamic EQ Mode", isOn: deesserDynModeBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Asymmetry Trim",
                value: asymmetryTrimBinding,
                range: -3.0...3.0,
                step: 0.1,
                formatValue: { String(format: "%+.1f dB", $0) },
                leftEndLabel: "−",
                rightEndLabel: "+"
            )

            Toggle("Limiter TP Guard", isOn: tpGuardBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))
        } header: {
            Text("Dynamics Refinement")
        } footer: {
            Text("Dialogue Gate raises the LUFS measurement floor to −60 dBFS. Asymmetry Trim compensates for transient waveform asymmetry at the clipper. TP Guard adds −1.5 dBFS ISP headroom in the limiter.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - System Utilities Section

    private var systemUtilitiesSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Latency Mode")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: latencyModeBinding) {
                    Text("Music").tag(LatencyMode.music)
                    Text("Movie").tag(LatencyMode.movie)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("Dither")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: ditherModeBinding) {
                    Text("Off").tag(DitherMode.bypass)
                    Text("TPDF").tag(DitherMode.tpdf)
                    Text("Shaped").tag(DitherMode.shaped)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Pause Gate", isOn: pauseGateBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("Sync Buffer to Latency Mode", isOn: syncBufferBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("Delta Solo Monitor", isOn: deltaSoloBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))
        } header: {
            Text("System Utilities")
        } footer: {
            Text("Music mode targets 128-frame I/O. Movie mode targets 512-frame I/O (better AV sync). Delta Solo outputs only the processing difference so you can hear what the dynamics chain is adding or removing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Advanced Bindings

    private var stereoModeBinding: Binding<StereoModeSelection> {
        Binding(
            get: { store.dynamicsConfig.advanced.stereoMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.stereoMode = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var dcOffsetEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.dcOffsetFilterEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.dcOffsetFilterEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var balanceBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.stereoBalancePosition) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.stereoBalancePosition = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var timeDelayBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.stereoTimeDelayMS) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.stereoTimeDelayMS = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var loudnessContourBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.loudnessContourEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.loudnessContourEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var deharshEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.deharshFilterEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.deharshFilterEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var deharshTiltBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.deharshTiltAmountDB) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.deharshTiltAmountDB = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var dialogueGateBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.loudnessDialogueGateEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.loudnessDialogueGateEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var deesserDynModeBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.deesserDynamicModeEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.deesserDynamicModeEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var asymmetryTrimBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.clipperAsymmetryTrimDB) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.clipperAsymmetryTrimDB = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var tpGuardBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.limiterTruePeakGuardEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.limiterTruePeakGuardEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var latencyModeBinding: Binding<LatencyMode> {
        Binding(
            get: { store.dynamicsConfig.advanced.latencyMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.latencyMode = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ditherModeBinding: Binding<DitherMode> {
        Binding(
            get: { store.dynamicsConfig.advanced.ditherMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.ditherMode = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var pauseGateBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.pauseGateEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.pauseGateEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var syncBufferBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.hardwareSyncBufferEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.hardwareSyncBufferEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var deltaSoloBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.deltaSoloActive },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.deltaSoloActive = val; store.updateAdvancedProcessing(adv) }
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
                    if !isFieldFocused { textValue = formatValue(newValue) }
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
            .replacingOccurrences(of: "LUFS", with: "")
            .replacingOccurrences(of: ": 1", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(normalised)
    }
}

// MARK: - Inline Header Widget

/// Compact dynamics widget shown inline in the main window header.
/// Shows 8-channel vertical LED gain-reduction meters alongside enable toggles
/// for each dynamics stage, plus a tooltip `?` button.
struct DynamicsInlineView: View {
    @EnvironmentObject var store: EqualiserStore

    // ── Ballistic GR state (60 Hz, 50 ms release) ─────────────────────────
    @State private var deEsserGR:  Float = 0.0
    @State private var mbLowGR:    Float = 0.0
    @State private var mbMidGR:    Float = 0.0
    @State private var mbHighGR:   Float = 0.0
    @State private var compGR:     Float = 0.0
    @State private var expanderGR: Float = 0.0
    @State private var clipperGR:  Float = 0.0
    @State private var limiterGR:  Float = 0.0

    // ── Peak-hold for clipper ──────────────────────────────────────────────
    @State private var clipperPeakGR:         Float = 0.0
    @State private var clipperPeakHoldFrames: Int   = 0

    // ── Dot colour pulse state ─────────────────────────────────────────────
    @State private var clipperEngaged: Bool = false
    @State private var limiterEngaged: Bool = false

    @State private var showDynamicsPanel = false
    @State private var showDefinitions   = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            VStack(alignment: .leading, spacing: 4) {
                inlineMeterToggleRow(
                    label: "Widener",
                    dotColor: simpleDotColor(store.dynamicsConfig.stereoWidener.isEnabled),
                    grDB: nil,
                    binding: wideEnabled
                )
                inlineMeterToggleRow(
                    label: "LUFS",
                    dotColor: simpleDotColor(store.dynamicsConfig.loudnessMatch.isEnabled),
                    grDB: nil,
                    binding: lufsEnabled
                )
                inlineMeterToggleRow(
                    label: "De-Esser",
                    dotColor: simpleDotColor(store.dynamicsConfig.deEsser.isEnabled),
                    grDB: deEsserGR,
                    binding: deEsserEnabledBinding
                )
                mbMeterToggleRow
                inlineMeterToggleRow(
                    label: "Comp.",
                    dotColor: simpleDotColor(store.dynamicsConfig.compressor.isEnabled),
                    grDB: compGR,
                    binding: compressorEnabledBinding
                )
                inlineMeterToggleRow(
                    label: "Expander",
                    dotColor: simpleDotColor(store.dynamicsConfig.expander.isEnabled),
                    grDB: expanderGR,
                    binding: expanderEnabledBinding
                )
                clipperMeterToggleRow
                inlineMeterToggleRow(
                    label: "Limiter",
                    dotColor: limiterDotColor,
                    grDB: limiterGR,
                    binding: limiterEnabledBinding
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
            Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
        ) { _ in
            updateMeters()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
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
                        definitionEntry(title: "Stereo Widener", body: "Three-band M/S processor that independently adjusts stereo width in the Low (< 200 Hz), Mid (200 Hz – 4 kHz), and High (> 4 kHz) regions.")
                        Divider()
                        definitionEntry(title: "LUFS Loudness Match", body: "Measures 3-second K-weighted loudness and continuously adjusts gain to hit the target LUFS level.")
                        Divider()
                        definitionEntry(title: "De-Esser", body: "Tames harsh, high-frequency sibilance ('S' and 'T' sounds) by applying frequency-selective gain reduction around a tunable centre frequency.")
                        Divider()
                        definitionEntry(title: "Multiband Compressor", body: "Independently controls the dynamics of three separate frequency bands using Linkwitz-Riley crossovers. Available in 24 dB/oct (gentle) or 48 dB/oct (steep) slope.")
                        Divider()
                        definitionEntry(title: "Compressor", body: "Wideband feed-forward compressor with soft-knee option that automatically balances dynamic range.")
                        Divider()
                        definitionEntry(title: "Expander", body: "Downward dynamic-range expander. Widens perceived dynamics by attenuating signals below threshold.")
                        Divider()
                        definitionEntry(title: "Clipper", body: "Analogue-style wave-shaper that gently rounds transient peaks before the limiter.")
                        Divider()
                        definitionEntry(title: "Limiter", body: "Look-ahead true peak limiter. Guarantees the output cannot exceed the ceiling.")
                    }
                    .padding(14)
                }
                .frame(width: 280, height: 420)
            }
        }
    }

    // MARK: - Meter + Toggle Rows

    /// Standard row: [meter] [dot] [label] [toggle]
    @ViewBuilder
    private func inlineMeterToggleRow(
        label: String,
        dotColor: Color,
        grDB: Float?,
        binding: Binding<Bool>
    ) -> some View {
        HStack(spacing: 5) {
            if let gr = grDB {
                grMeter(grDB: gr, peakHold: nil)
            } else {
                Spacer().frame(width: 4, height: 20)
            }
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

    /// Multiband row: three stacked sub-meters + one M-Band toggle.
    private var mbMeterToggleRow: some View {
        HStack(spacing: 5) {
            VStack(spacing: 2) {
                miniGrMeter(grDB: mbLowGR,  label: "L")
                miniGrMeter(grDB: mbMidGR,  label: "M")
                miniGrMeter(grDB: mbHighGR, label: "H")
            }
            Circle()
                .fill(simpleDotColor(store.dynamicsConfig.multibandCompressor.isEnabled))
                .frame(width: 6, height: 6)
            Text("M-Band")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Toggle("", isOn: mbEnabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
        }
    }

    /// Clipper row: meter with peak-hold segment.
    private var clipperMeterToggleRow: some View {
        HStack(spacing: 5) {
            grMeter(grDB: clipperGR, peakHold: clipperPeakHoldFrames > 0 ? clipperPeakGR : nil)
            Circle()
                .fill(clipperDotColor)
                .frame(width: 6, height: 6)
            Text("Clipper")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Toggle("", isOn: clipperEnabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
        }
    }

    // MARK: - Meter Views

    /// Full-height (20 px) vertical GR meter: fills downward from 0 dB.
    /// Color: green → yellow → orange → red as GR increases.
    @ViewBuilder
    private func grMeter(grDB: Float, peakHold: Float?) -> some View {
        let mag = Double(max(0, min(-grDB, 24.0))) / 24.0
        let color = meterColor(grDB: grDB)

        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 4, height: 20)

            if mag > 0 {
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .frame(width: 4, height: max(1, geo.size.height * mag))
                }
                .frame(width: 4, height: 20)
                .clipped()
            }

            // Peak-hold segment (1 px bright line)
            if let peakDB = peakHold {
                let peakFrac = Double(max(0, min(-peakDB, 24.0))) / 24.0
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 4, height: 2)
                        .offset(y: max(0, geo.size.height * peakFrac - 1))
                }
                .frame(width: 4, height: 20)
                .clipped()
            }
        }
        .frame(width: 4, height: 20)
        .animation(.linear(duration: 1.0 / 60.0), value: mag)
    }

    /// Mini sub-meter for each MB band (6 px tall each).
    @ViewBuilder
    private func miniGrMeter(grDB: Float, label: String) -> some View {
        let mag = Double(max(0, min(-grDB, 24.0))) / 24.0
        let color = meterColor(grDB: grDB)

        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 4, height: 6)
            if mag > 0 {
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .frame(width: 4, height: max(1, geo.size.height * mag))
                }
                .frame(width: 4, height: 6)
                .clipped()
            }
        }
        .frame(width: 4, height: 6)
        .animation(.linear(duration: 1.0 / 60.0), value: mag)
        .help("\(label) band GR")
    }

    private func meterColor(grDB: Float) -> Color {
        let mag = -grDB
        switch mag {
        case ..<4:  return .green
        case ..<12: return .yellow
        case ..<18: return .orange
        default:    return .red
        }
    }

    // MARK: - Ballistic Update

    private func updateMeters() {
        let alpha: Float = 0.72  // ≈ 50 ms release at 60 Hz

        func smooth(_ state: inout Float, target: Float) {
            // Instant attack (more GR), ballistic release (less GR)
            if target < state {
                state = target
            } else {
                state = alpha * state + (1.0 - alpha) * target
            }
        }

        smooth(&deEsserGR,  target: store.deEsserGainReductionDB)
        smooth(&mbLowGR,    target: store.mbLowGainReductionDB)
        smooth(&mbMidGR,    target: store.mbMidGainReductionDB)
        smooth(&mbHighGR,   target: store.mbHighGainReductionDB)
        smooth(&compGR,     target: store.compressorGainReductionDB)
        smooth(&expanderGR, target: store.expanderGainReductionDB)
        smooth(&limiterGR,  target: store.limiterGainReductionDB)

        let rawClipperGR = store.clipperGainReductionDB
        smooth(&clipperGR, target: rawClipperGR)

        // Clipper peak-hold: 2-second hold when clipper is engaged
        if rawClipperGR < -0.5 {
            if rawClipperGR < clipperPeakGR { clipperPeakGR = rawClipperGR }
            clipperPeakHoldFrames = 120  // 2 s × 60 Hz
        } else if clipperPeakHoldFrames > 0 {
            clipperPeakHoldFrames -= 1
            if clipperPeakHoldFrames == 0 { clipperPeakGR = 0.0 }
        }

        clipperEngaged = store.clipperEngaged
        limiterEngaged = store.limiterGainReductionDB < -0.5
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func definitionEntry(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Text(body).font(.caption).foregroundStyle(.secondary)
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

    private var wideEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.stereoWidener.isEnabled },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.isEnabled = v; store.updateStereoWidener(c) }
        )
    }

    private var lufsEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.loudnessMatch.isEnabled },
            set: { v in var c = store.dynamicsConfig.loudnessMatch; c.isEnabled = v; store.updateLoudnessMatch(c) }
        )
    }

    private var deEsserEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.deEsser.isEnabled },
            set: { v in var c = store.dynamicsConfig.deEsser; c.isEnabled = v; store.updateDeEsser(c) }
        )
    }

    private var mbEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.isEnabled = v; store.updateMultibandCompressor(c) }
        )
    }

    private var compressorEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.compressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.compressor; c.isEnabled = v; store.updateCompressor(c) }
        )
    }

    private var expanderEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.expander.isEnabled },
            set: { v in var c = store.dynamicsConfig.expander; c.isEnabled = v; store.updateExpander(c) }
        )
    }

    private var clipperEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.softClipper.isEnabled },
            set: { v in var sc = store.dynamicsConfig.softClipper; sc.isEnabled = v; store.updateSoftClipper(sc) }
        )
    }

    private var limiterEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.limiter.isEnabled },
            set: { v in var lim = store.dynamicsConfig.limiter; lim.isEnabled = v; store.updateLimiter(lim) }
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
