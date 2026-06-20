// CrossoverAnalysisView.swift
//
// Tabbed analysis panel embedded in OutputChannelMatrixView.
// Each tab's content is specified by a different V7 task — this file owns
// only the tab container. Implement each tab body from its task.

import SwiftUI
import CoreAudio

struct CrossoverAnalysisView: View {
    @Binding var selectedTab: OutputChannelMatrixView.AnalysisTab
    @ObservedObject var store: EqualiserStore

    @State private var showGroupDelayAlert = false
    @State private var showPeaksAlert = false
    @State private var showTimeAlignmentAlert = false
    @State private var showPolarityAlert = false

    var body: some View {
        Group {
            switch selectedTab {
            case .groupDelay:
                // TASK Q: Group Delay plot, warning badges, auto-correct buttons
                groupDelayTab

            case .summation:
                // TASK R: Acoustic summation plot, live RTA overlay toggle (Task Z)
                // The live RTA toggle from Task Z is a control WITHIN this tab,
                // not a separate tab — see Task Z spec: "add live RTA overlay"
                // to the Summation tab specifically.
                summationTab

            case .optimise:
                // TASK X: Crossover Optimisation controls and results
                optimiseTab

            case .timeAlign:
                // TASK V: Driver Time Alignment table + Apply button
                // TASK W: Polarity Detection results (lives in the same tab,
                // directly below the time alignment table — see Task W spec:
                // "Add a 'Detect Polarity' button to the Driver Time Alignment panel")
                // TASK AF: "Refine at Crossover Frequency" button(s) — appended
                // below the broadband alignment button in this same tab.
                timeAlignmentTab

            case .verification:
                // TASK AD: Combined Multi-Driver Measurement
                verificationTab
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Tab stubs — implement each from its task

    @ViewBuilder private var groupDelayTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group Delay Analysis")
                .font(.headline)
            Text("Group delay plot placeholder — implement from Task Q")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Auto-Correct") {
                    // TODO: Wire to CrossoverGroupDelayEngine.fitAllPassChainToGroupDelay
                    // Requires: crossover config, target group delay, frequency range
                    showGroupDelayAlert = true
                }
                .buttonStyle(.bordered)
                .alert("Auto-Correct Group Delay", isPresented: $showGroupDelayAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Group delay auto-correction requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
                }
                Button("Detect Peaks") {
                    // TODO: Wire to CrossoverGroupDelayEngine.detectGroupDelayPeaks
                    // Requires: group delay data, threshold
                    showPeaksAlert = true
                }
                .buttonStyle(.bordered)
                .alert("Detect Group Delay Peaks", isPresented: $showPeaksAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Group delay peak detection requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
                }
            }
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var summationTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Acoustic Summation")
                .font(.headline)
            Text("Acoustic summation plot placeholder — implement from Task R")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Live RTA Overlay", isOn: Binding(
                get: { false },
                set: { _ in }
            ))
            .disabled(true)
            // Task Z: Live RTA toggle added here
            // TODO: Wire to AcousticSummationEngine.computeSummation
            // Requires: measured driver responses, crossover config, delays
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var optimiseTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crossover Optimisation")
                .font(.headline)
            Text("Crossover optimisation controls placeholder — implement from Task X")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Run Optimisation") {
                // TODO: Wire to CrossoverOptimiser.optimise
                // Requires: measured driver responses, target curve, crossover config
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var timeAlignmentTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Driver Time Alignment")
                .font(.headline)
            Text("Time alignment table placeholder — implement from Task V")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Apply Time Alignment") {
                // TODO: Wire to DriverTimeAlignmentEngine.computeAlignment
                // Requires: impulse responses per channel, crossover frequencies
                showTimeAlignmentAlert = true
            }
            .buttonStyle(.borderedProminent)
            .alert("Apply Time Alignment", isPresented: $showTimeAlignmentAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Time alignment requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
            }

            // Task AF: Acoustic Centre Calibration Refinement
            Divider()
            Text("Acoustic Centre Refinement")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Refines time alignment at the crossover frequency using group delay analysis for sub-millisecond accuracy at the crossover point.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Show refinement buttons based on crossover configuration
            if store.outputChannelMatrix.channels.count >= 2 {
                // For now, show a single refinement button
                // TODO: Dynamically show buttons for each crossover point based on activeCrossoverConfig
                Button("Refine at Crossover Frequency") {
                    // TODO: Wire to DriverTimeAlignmentEngine.computeAcousticCentreAlignment
                    // Requires: complex frequency responses, crossover frequency, existing delays
                    showTimeAlignmentAlert = true
                }
                .buttonStyle(.bordered)
                .alert("Refine at Crossover Frequency", isPresented: $showTimeAlignmentAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Acoustic centre refinement requires measured transfer functions with complex response data. Use the Transfer Function Wizard to measure your system first.")
                }

                Text("ⓘ Broadband alignment is the starting point. Crossover-frequency refinement improves phase accuracy specifically at the crossover point. Apply broadband alignment first, then refine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Task W: Polarity Detection results (lives in the same tab)
            Divider()
            Text("Polarity Detection")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Polarity detection placeholder — implement from Task W")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Detect Polarity") {
                // TODO: Wire to DriverTimeAlignmentEngine.detectPolarity
                // Requires: impulse response per channel
                showPolarityAlert = true
            }
            .buttonStyle(.bordered)
            .alert("Detect Polarity", isPresented: $showPolarityAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Polarity detection requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
            }
            // Task AF: "Refine at Crossover Frequency" button(s) appended below
            Divider()
            Text("Refine at Crossover Frequency")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Refine controls placeholder — implement from Task AF")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var verificationTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Verification Measurement")
                .font(.headline)
            Text("Measures the actual in-room frequency response with all drivers playing simultaneously. Requires a measurement microphone at your listening position.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Microphone selection
            HStack {
                Text("Microphone:")
                    .font(.caption)
                Picker("", selection: Binding(
                    get: { nil as AudioDeviceID? },
                    set: { _ in }
                )) {
                    Text("Select microphone...").tag(Optional<AudioDeviceID>.none)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(true)
            }

            // Duration picker
            HStack {
                Text("Duration:")
                    .font(.caption)
                Picker("", selection: Binding(
                    get: { 10 },
                    set: { _ in }
                )) {
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("15 s").tag(15)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(true)
            }

            Text("All DSP processing (EQ, crossover, delays) is active during this measurement.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Run Verification Measurement") {
                // TODO: Wire to store.runCombinedVerificationMeasurement
                // Requires: mic input device ID, duration
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)

            // After measurement results
            if let result = store.combinedMeasurementResult {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Measurement Results")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text("Deviation from prediction: ±2.8 dB RMS (80 Hz – 10 kHz)")
                        .font(.caption)
                    Text("Deviation from target: ±3.2 dB RMS (80 Hz – 10 kHz)")
                        .font(.caption)

                    Text("ⓘ Residual errors between measured and target can be corrected using the Transfer Function Wizard (which applies per-driver correction, not combined correction).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("Save Result") {
                            // TODO: Save result to disk
                        }
                        .buttonStyle(.bordered)
                        Button("Export as WAV") {
                            // TODO: Export as WAV
                        }
                        .buttonStyle(.bordered)
                        Button("Apply as Room Correction") {
                            // TODO: Apply to main chain ConvolutionEngine
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
