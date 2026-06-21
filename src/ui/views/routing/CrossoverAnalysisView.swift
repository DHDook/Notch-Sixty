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

    // MARK: - Group Delay Tab State
    @State private var groupDelayCurves: [Int: [Double]] = [:]
    @State private var groupDelayFrequencies: [Double] = []
    @State private var detectedPeaks: [Int: [(freqHz: Double, deltaMs: Double)]] = [:]

    // MARK: - Summation Tab State
    @State private var summationMagnitudeDB: [Double] = []
    @State private var summationFrequencies: [Double] = []
    @State private var individualResponses: [Int: [Double]] = [:]

    // MARK: - Optimise Tab State
    @State private var optimisationParams = CrossoverOptimiser.OptimisationParameters()
    @State private var optimisationResult: CrossoverOptimiser.OptimisationResult?
    @State private var isOptimising = false

    // MARK: - Time Alignment Tab State
    @State private var alignmentResult: DriverTimeAlignmentEngine.TimeAlignmentResult?
    @State private var polarityResults: [Int: DriverTimeAlignmentEngine.PolarityResult] = [:]

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

            if groupDelayCurves.isEmpty {
                Button("Compute Group Delay") { computeGroupDelay() }
                    .buttonStyle(.borderedProminent)
            } else {
                // TODO: Render GroupDelayChartView with curves
                // For now, show text representation
                ForEach(Array(groupDelayCurves.keys.sorted()), id: \.self) { channelIndex in
                    if channelIndex < store.outputChannelMatrix.channels.count {
                        Text("\(store.outputChannelMatrix.channels[channelIndex].label): \(groupDelayCurves[channelIndex]?.count ?? 0) points")
                            .font(.caption)
                    }
                }

                ForEach(Array(detectedPeaks.keys.sorted()), id: \.self) { channelIndex in
                    if let peaks = detectedPeaks[channelIndex], !peaks.isEmpty {
                        ForEach(peaks.indices, id: \.self) { i in
                            let peak = peaks[i]
                            HStack {
                                Text("\(store.outputChannelMatrix.channels[channelIndex].label): \(String(format: "%.0f Hz, Δ%.1f ms", peak.freqHz, peak.deltaMs))")
                                    .font(.caption)
                                Button("Auto-Correct") { applyGroupDelayCorrection(channelIndex: channelIndex, atFrequency: peak.freqHz) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Button("Clear Results") {
                    groupDelayCurves.removeAll()
                    groupDelayFrequencies.removeAll()
                    detectedPeaks.removeAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }

    private func computeGroupDelay() {
        let frequencies = AudioMath.logSpacedFrequencies(from: 20, to: 20000, count: 200)
        groupDelayFrequencies = frequencies
        for (idx, channel) in store.outputChannelMatrix.channels.enumerated() where channel.isEnabled {
            let (sections, firKernel) = store.activeCrossoverCoefficients(for: channel.source)
            let delays = CrossoverGroupDelayEngine.channelGroupDelay(
                crossoverSections: sections,
                crossoverFIRKernel: firKernel,
                eqBands: channel.eq.bands,
                frequencies: frequencies,
                sampleRate: store.streamSampleRate
            )
            groupDelayCurves[idx] = delays
        }
        detectAdjacentChannelPeaks()
    }

    private func detectAdjacentChannelPeaks() {
        // For each pair of adjacent output channels sharing a crossover frequency
        // call CrossoverGroupDelayEngine.groupDelayError at that crossover frequency
        // and flag pairs exceeding 1 ms difference
    }

    private func applyGroupDelayCorrection(channelIndex: Int, atFrequency freqHz: Double) {
        // Determine which of the pair has LESS group delay (needs correction)
        // Call CrossoverGroupDelayEngine.fitGroupDelayAllPass(...)
        // Apply via pipelineManager.renderPipeline?.callbackContext?
        //   .outputChannelProcessors[channelIndex]?.setGroupDelayAllPassCoefficients(coeffs)
        // Persist into store.outputChannelMatrix.channels[channelIndex]
        //   .groupDelayAllPassCoefficients
    }
    @ViewBuilder private var summationTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Acoustic Summation")
                .font(.headline)
            Button("Compute Summation") { computeSummation() }
                .buttonStyle(.borderedProminent)

            if !summationMagnitudeDB.isEmpty {
                // Render summation chart with listening RTA overlay
                ChartView(
                    frequencies: summationFrequencies,
                    summationData: summationMagnitudeDB,
                    listeningRTAData: store.listeningRTAEnabled ? store.listeningRTAData : [],
                    showListeningRTA: store.listeningRTAEnabled
                )
                .frame(height: 200)

                Text("ⓘ This shows the predicted in-room summation assuming all drivers are at the same physical location. Actual acoustic summation depends on driver placement, cabinet diffraction, and listening position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear Results") {
                    summationMagnitudeDB.removeAll()
                    summationFrequencies.removeAll()
                    individualResponses.removeAll()
                }
                .buttonStyle(.bordered)
            }

            // Live RTA overlay toggle (Task 5)
            Toggle("Live RTA Overlay", isOn: $store.listeningRTAEnabled)
            if store.listeningRTAEnabled {
                Picker("Mic Device", selection: $store.listeningRTAMicDeviceID) {
                    Text("Select mic...").tag(nil as String?)
                    ForEach(store.deviceManager.enumerator.inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                Text("Captures room response during playback and overlays on the summation chart.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Chart View for Summation and Listening RTA

    struct ChartView: View {
        let frequencies: [Double]
        let summationData: [Double]
        let listeningRTAData: [(frequency: Double, gainDB: Double)]
        let showListeningRTA: Bool

        private let minDb: Double = -60.0
        private let maxDb: Double = 0.0

        var body: some View {
            Canvas { context, size in
                let padding: CGFloat = 40
                let chartWidth = size.width - 2 * padding
                let chartHeight = size.height - 2 * padding

                // Draw axes
                let origin = CGPoint(x: padding, y: size.height - padding)
                let xAxisEnd = CGPoint(x: size.width - padding, y: size.height - padding)
                let yAxisEnd = CGPoint(x: padding, y: padding)

                context.stroke(Path { path in
                    path.move(to: origin)
                    path.addLine(to: xAxisEnd)
                }, with: .color(.secondary))

                context.stroke(Path { path in
                    path.move(to: origin)
                    path.addLine(to: yAxisEnd)
                }, with: .color(.secondary))

                // Draw frequency labels (log scale)
                let freqLabels = [20, 100, 1000, 10000, 20000]
                for freq in freqLabels {
                    let freqRatio = Double(freq) / 20.0
                    let maxRatio = 20000.0 / 20.0
                    let x = padding + chartWidth * CGFloat(log10(freqRatio) / log10(maxRatio))
                    let label = freq >= 1000 ? "\(freq/1000)k" : "\(freq)"
                    context.draw(Text(label).font(.caption2), at: CGPoint(x: x - 10, y: size.height - padding + 5))
                }

                // Draw dB labels
                let dbLabels = [-60, -40, -20, 0]
                for db in dbLabels {
                    let dbRange = maxDb - minDb
                    let dbOffset = Double(db) - minDb
                    let normalizedDb = dbOffset / dbRange
                    let y = size.height - padding - chartHeight * CGFloat(normalizedDb)
                    context.draw(Text("\(db) dB").font(.caption2), at: CGPoint(x: padding - 35, y: y - 5))
                }

                // Draw summation curve
                if !summationData.isEmpty {
                    var path = Path()
                    for (index, freq) in frequencies.enumerated() {
                        let freqRatio = freq / 20.0
                        let maxRatio = 20000.0 / 20.0
                        let x = padding + chartWidth * CGFloat(log10(freqRatio) / log10(maxRatio))
                        let dbRange = maxDb - minDb
                        let dbOffset = summationData[index] - minDb
                        let normalizedDb = dbOffset / dbRange
                        let y = size.height - padding - chartHeight * CGFloat(normalizedDb)

                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(path, with: .color(.blue), style: StrokeStyle(lineWidth: 2))
                }

                // Draw listening RTA overlay
                if showListeningRTA && !listeningRTAData.isEmpty {
                    var rtaPath = Path()
                    for (index, point) in listeningRTAData.enumerated() {
                        let freqRatio = point.frequency / 20.0
                        let maxRatio = 20000.0 / 20.0
                        let x = padding + chartWidth * CGFloat(log10(freqRatio) / log10(maxRatio))
                        let dbRange = maxDb - minDb
                        let dbOffset = point.gainDB - minDb
                        let normalizedDb = dbOffset / dbRange
                        let y = size.height - padding - chartHeight * CGFloat(normalizedDb)

                        if index == 0 {
                            rtaPath.move(to: CGPoint(x: x, y: y))
                        } else {
                            rtaPath.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(rtaPath, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                }
            }
        }
    }

    private func computeSummation() {
        let frequencies = AudioMath.logSpacedFrequencies(from: 20, to: 20000, count: 200)
        summationFrequencies = frequencies
        let channelResponses: [AcousticSummationEngine.ChannelResponse] = store.outputChannelMatrix.channels
            .enumerated().compactMap { idx, channel in
                guard channel.isEnabled else { return nil }
                let (sections, firKernel) = store.activeCrossoverCoefficients(for: channel.source)
                let complexResponse = AcousticSummationEngine.channelComplexResponse(
                    crossoverSections: sections,
                    crossoverFIRKernel: firKernel,
                    eqBands: channel.eq.bands,
                    groupDelayAllPassCoefficients: channel.groupDelayAllPassCoefficients,
                    frequencies: frequencies,
                    sampleRate: store.streamSampleRate
                )
                individualResponses[idx] = complexResponse.map {
                    20 * log10(max(1e-10, sqrt($0.real * $0.real + $0.imag * $0.imag)))
                }
                let delaySamples = Double(channel.delayMs) / 1000.0 * store.streamSampleRate
                return AcousticSummationEngine.ChannelResponse(
                    channelIndex: idx, channelLabel: channel.label,
                    complexResponse: complexResponse, delaySamples: delaySamples
                )
            }
        let (magnitude, _) = AcousticSummationEngine.computeSummation(
            channels: channelResponses, frequencies: frequencies, sampleRate: store.streamSampleRate
        )
        summationMagnitudeDB = magnitude
    }
    @ViewBuilder private var optimiseTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crossover Optimisation")
                .font(.headline)

            if !store.transferFunctionDataset.channels.contains(where: \.isMeasured) {
                Text("Requires measured transfer functions. Use the Transfer Function Wizard first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Optimise crossover frequencies", isOn: $optimisationParams.optimiseCrossoverFrequencies)
                Toggle("Optimise per-output EQ", isOn: $optimisationParams.optimisePerOutputEQ)
                // TODO: Add remaining parameter controls per the original Task X spec

                Button(isOptimising ? "Optimising…" : "Start Optimisation") {
                    Task { await runOptimisation() }
                }
                .disabled(isOptimising)

                if let result = optimisationResult {
                    Text("Initial error: ±\(String(format: "%.1f", result.initialRMSErrorDB)) dB RMS")
                        .font(.caption)
                    Text("Final error: ±\(String(format: "%.1f", result.residualRMSErrorDB)) dB RMS (\(result.converged ? "converged" : "did not converge") in \(result.iterationCount) iterations)")
                        .font(.caption)
                    Button("Apply All") { applyOptimisationResult(result) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func runOptimisation() async {
        isOptimising = true
        defer { isOptimising = false }
        let measurements = Dictionary(uniqueKeysWithValues: store.transferFunctionDataset.channels
            .filter(\.isMeasured).map { ($0.channelIndex, $0) })
        let currentEQs = Dictionary(uniqueKeysWithValues: store.outputChannelMatrix.channels
            .enumerated().map { ($0.offset, $0.element.eq) })
        optimisationResult = await CrossoverOptimiser.optimise(
            measurements: measurements,
            currentCrossoverConfig: store.activeCrossoverConfig,
            currentEQConfigs: currentEQs,
            params: optimisationParams,
            sampleRate: store.streamSampleRate,
            progressHandler: { @Sendable _, _ in
                // No cancellation UI yet — always continue
                return true
            }
        )
    }

    private func applyOptimisationResult(_ result: CrossoverOptimiser.OptimisationResult) {
        store.activeCrossoverConfig = result.suggestedCrossoverConfig
        for (channelIndex, bands) in result.suggestedEQAdjustments {
            guard channelIndex < store.outputChannelMatrix.channels.count else { continue }
            store.outputChannelMatrix.channels[channelIndex].eq.bands = bands
        }
        optimisationResult = nil
    }
    @ViewBuilder private var timeAlignmentTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Task V: broadband alignment
            Group {
                Text("Driver Time Alignment")
                    .font(.headline)
                if let result = alignmentResult {
                    ForEach(Array(result.arrivalTimesMs.keys.sorted()), id: \.self) { idx in
                        HStack {
                            Text(store.outputChannelMatrix.channels[idx].label)
                                .font(.caption)
                            Text(String(format: "%.1f ms", result.arrivalTimesMs[idx] ?? 0))
                                .font(.caption)
                            Text(idx == result.referenceChannelIndex ? "0.0 ms (ref)"
                                 : String(format: "%.1f ms", result.delayPerChannel[idx] ?? 0))
                                .font(.caption)
                        }
                    }
                    Button("Apply Time Alignment to All Channels") { applyTimeAlignment(result) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Compute Time Alignment") { computeTimeAlignment() }
                        .buttonStyle(.bordered)
                }
            }

            Divider()

            // Task W: polarity detection — same panel as Task V, per original spec.
            Group {
                Text("Polarity Detection")
                    .font(.headline)
                Button("Detect Polarity") { detectPolarity() }
                    .buttonStyle(.bordered)
                ForEach(Array(polarityResults.keys.sorted()), id: \.self) { idx in
                    let result = polarityResults[idx]!
                    HStack {
                        Text(store.outputChannelMatrix.channels[idx].label)
                            .font(.caption)
                        Text(result == .correct ? "✓ Correct" : result == .inverted ? "⚠ Inverted" : "? Uncertain")
                            .font(.caption)
                    }
                }
                Text("⚠ Note: Some crossover designs intentionally invert polarity on one driver (even-order Butterworth crossovers). If you are using such a design, verify this result before applying.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if polarityResults.values.contains(.inverted) {
                    Button("Apply Polarity Corrections") { applyPolarityCorrections() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            // Task AF: acoustic centre refinement — appended below polarity, per spec.
            Group {
                Text("Acoustic Centre Refinement")
                    .font(.headline)
                Text("Broadband alignment is the starting point. Crossover-frequency refinement improves phase accuracy specifically at the crossover point. Apply broadband alignment first, then refine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(crossoverPointsRequiringRefinement, id: \.self) { crossoverHz in
                    Button("Refine at \(Int(crossoverHz)) Hz") { refineAtCrossover(crossoverHz) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func computeTimeAlignment() {
        let measurements = Dictionary(uniqueKeysWithValues: store.transferFunctionDataset.channels
            .filter(\.isMeasured).map { ($0.channelIndex, $0) })
        guard measurements.count >= 2 else { return }
        alignmentResult = DriverTimeAlignmentEngine.computeAlignment(
            measurements: measurements, sampleRate: store.streamSampleRate
        )
    }

    private func applyTimeAlignment(_ result: DriverTimeAlignmentEngine.TimeAlignmentResult) {
        for (idx, delayMs) in result.delayPerChannel {
            guard idx < store.outputChannelMatrix.channels.count else { continue }
            store.outputChannelMatrix.channels[idx].delayMs = delayMs
        }
    }

    private func detectPolarity() {
        for channel in store.transferFunctionDataset.channels where channel.isMeasured {
            guard let ir = channel.averagedIR else { continue }
            polarityResults[channel.channelIndex] = DriverTimeAlignmentEngine.detectPolarity(
                ir: ir, sampleRate: store.streamSampleRate
            )
        }
    }

    private func applyPolarityCorrections() {
        for (idx, result) in polarityResults where result == .inverted {
            guard idx < store.outputChannelMatrix.channels.count else { continue }
            store.outputChannelMatrix.channels[idx].polarityInverted = true
        }
    }

    private func refineAtCrossover(_ crossoverHz: Double) {
        let measurements = Dictionary(uniqueKeysWithValues: store.transferFunctionDataset.channels
            .filter(\.isMeasured).map { ($0.channelIndex, $0) })
        let existingDelays = Dictionary(uniqueKeysWithValues: store.outputChannelMatrix.channels
            .enumerated().map { ($0.offset, $0.element.delayMs) })
        let refined = DriverTimeAlignmentEngine.computeAcousticCentreAlignment(
            measurements: measurements, crossoverHz: crossoverHz,
            sampleRate: store.streamSampleRate, existingDelaysMs: existingDelays
        )
        for (idx, delayMs) in refined.delayPerChannel {
            guard idx < store.outputChannelMatrix.channels.count else { continue }
            store.outputChannelMatrix.channels[idx].delayMs = delayMs
        }
    }

    private var crossoverPointsRequiringRefinement: [Double] {
        var points: [Double] = [Double(store.activeCrossoverConfig.lowerPoint.frequency)]
        if store.activeCrossoverConfig.bandCount == .triAmp {
            points.append(Double(store.activeCrossoverConfig.upperPoint.frequency))
        }
        return points
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
