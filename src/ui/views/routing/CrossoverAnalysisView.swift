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
    @State private var selectedTargetCurveName: String = "Harman room"

    // MARK: - Time Alignment Tab State
    @State private var alignmentResult: DriverTimeAlignmentEngine.TimeAlignmentResult?
    @State private var polarityResults: [Int: DriverTimeAlignmentEngine.PolarityResult] = [:]

    // MARK: - Verification Tab State
    @State private var selectedVerificationMic: AudioDeviceID?
    @State private var verificationDuration: Int = 10
    @State private var availableVerificationMics: [(id: AudioDeviceID, name: String)] = []

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
        detectedPeaks.removeAll()

        let channels = store.outputChannelMatrix.channels.enumerated().filter { $0.element.isEnabled }
        guard channels.count >= 2 else { return }

        let lowerCrossoverHz = Double(store.activeCrossoverConfig.lowerPoint.frequency)
        let upperCrossoverHz = Double(store.activeCrossoverConfig.upperPoint.frequency)

        // Check pairs around lower crossover
        for i in 0..<(channels.count - 1) {
            let channelA = channels[i]
            let channelB = channels[i + 1]

            guard let delaysA = groupDelayCurves[channelA.offset],
                  let delaysB = groupDelayCurves[channelB.offset] else { continue }

            let deltaArray = CrossoverGroupDelayEngine.groupDelayError(
                channelADelays: delaysA,
                channelBDelays: delaysB,
                crossoverHz: lowerCrossoverHz,
                frequencies: groupDelayFrequencies
            )

            // Get the delta at the crossover frequency
            let crossoverIdx = groupDelayFrequencies.firstIndex(where: { abs($0 - lowerCrossoverHz) < 10 }) ?? groupDelayFrequencies.count / 2
            let deltaMs = deltaArray[crossoverIdx]

            if abs(deltaMs) > 1.0 {
                let applyToChannelA = delaysA.reduce(0, +) < delaysB.reduce(0, +)
                detectedPeaks[applyToChannelA ? channelA.offset : channelB.offset, default: []].append(
                    (freqHz: lowerCrossoverHz, deltaMs: deltaMs)
                )
            }
        }

        // Check pairs around upper crossover (tri-amp only)
        if store.activeCrossoverConfig.bandCount == .triAmp && channels.count >= 3 {
            for i in 1..<(channels.count - 1) {
                let channelA = channels[i]
                let channelB = channels[i + 1]

                guard let delaysA = groupDelayCurves[channelA.offset],
                      let delaysB = groupDelayCurves[channelB.offset] else { continue }

                let deltaArray = CrossoverGroupDelayEngine.groupDelayError(
                    channelADelays: delaysA,
                    channelBDelays: delaysB,
                    crossoverHz: upperCrossoverHz,
                    frequencies: groupDelayFrequencies
                )

                // Get the delta at the crossover frequency
                let crossoverIdx = groupDelayFrequencies.firstIndex(where: { abs($0 - upperCrossoverHz) < 10 }) ?? groupDelayFrequencies.count / 2
                let deltaMs = deltaArray[crossoverIdx]

                if abs(deltaMs) > 1.0 {
                    let applyToChannelA = delaysA.reduce(0, +) < delaysB.reduce(0, +)
                    detectedPeaks[applyToChannelA ? channelA.offset : channelB.offset, default: []].append(
                        (freqHz: upperCrossoverHz, deltaMs: deltaMs)
                    )
                }
            }
        }
    }

    private func applyGroupDelayCorrection(channelIndex: Int, atFrequency freqHz: Double) {
        guard let delays = groupDelayCurves[channelIndex] else { return }

        // Find the adjacent channel with higher delay to determine the required correction
        let channels = store.outputChannelMatrix.channels.enumerated().filter { $0.element.isEnabled }
        guard let currentIdx = channels.firstIndex(where: { $0.offset == channelIndex }) else { return }

        var adjacentDelays: [Double] = []
        if currentIdx > 0 {
            let prevChannel = channels[currentIdx - 1]
            if let prevDelays = groupDelayCurves[prevChannel.offset] {
                adjacentDelays.append(prevDelays.reduce(0, +))
            }
        }
        if currentIdx < channels.count - 1 {
            let nextChannel = channels[currentIdx + 1]
            if let nextDelays = groupDelayCurves[nextChannel.offset] {
                adjacentDelays.append(nextDelays.reduce(0, +))
            }
        }

        let currentDelay = delays.reduce(0, +)
        let avgAdjacentDelay = adjacentDelays.isEmpty ? currentDelay : adjacentDelays.reduce(0, +) / Double(adjacentDelays.count)

        // Compute delay error array (current - adjacent) at each frequency
        let delayErrorArray = delays.map { avgAdjacentDelay - $0 }

        guard delayErrorArray.contains(where: { abs($0) > 0.1 }) else { return }

        // Fit all-pass coefficients to correct the delay error
        let coeffs = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: delayErrorArray,
            applyToChannelA: true,
            crossoverHz: freqHz,
            frequencies: groupDelayFrequencies,
            sampleRate: store.streamSampleRate
        )

        // Apply to the output channel processor
        store.routingCoordinator.pipelineManager.renderPipeline?.callbackContext?
            .outputChannelProcessors[channelIndex]?
            .setGroupDelayAllPassCoefficients(coeffs, sampleRate: store.streamSampleRate)

        // Persist to config
        guard channelIndex < store.outputChannelMatrix.channels.count else { return }
        store.outputChannelMatrix.channels[channelIndex].groupDelayAllPassCoefficients = coeffs
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
                Toggle("Optimise crossover slopes", isOn: $optimisationParams.optimiseCrossoverSlopes)
                Toggle("Optimise delay", isOn: $optimisationParams.optimiseDelay)
                Toggle("Optimise per-output EQ", isOn: $optimisationParams.optimisePerOutputEQ)

                Divider()

                Text("Target Curve")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Target Curve", selection: $selectedTargetCurveName) {
                    ForEach(TargetCurveLibrary.allCurves.filter { !$0.appliesToSubBandOnly }, id: \.name) { curve in
                        Text(curve.name).tag(curve.name)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .onChange(of: selectedTargetCurveName) { _, newValue in
                    if let curve = TargetCurveLibrary.allCurves.first(where: { $0.name == newValue }) {
                        optimisationParams.targetCurve = curve.curve
                    }
                }

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
        let channelDelays = Dictionary(uniqueKeysWithValues: store.outputChannelMatrix.channels
            .enumerated().map { ($0.offset, Double($0.element.delayMs)) })
        optimisationResult = await CrossoverOptimiser.optimise(
            measurements: measurements,
            channelDelays: channelDelays,
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
                Picker("Microphone", selection: $selectedVerificationMic) {
                    Text("Select microphone...").tag(nil as AudioDeviceID?)
                    ForEach(availableVerificationMics, id: \.id) { device in
                        Text(device.name).tag(device.id as AudioDeviceID?)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .onAppear {
                availableVerificationMics = listInputDevices()
            }

            // Duration picker
            HStack {
                Text("Duration:")
                    .font(.caption)
                Picker("Duration", selection: $verificationDuration) {
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("15 s").tag(15)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            Text("All DSP processing (EQ, crossover, delays) is active during this measurement.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Run Verification Measurement") {
                if let micID = selectedVerificationMic {
                    Task {
                        await store.runCombinedMeasurement(
                            micInputDeviceID: micID,
                            channelIndices: store.outputChannelMatrix.channels.indices.filter {
                                store.outputChannelMatrix.channels[$0].isEnabled
                            }.map { $0 },
                            sweepDurationSeconds: Double(verificationDuration)
                        )
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedVerificationMic == nil)

            // After measurement results
            if store.combinedMeasurementResult != nil {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Measurement Results")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    if let result = store.combinedMeasurementResult {
                        let frequencies = result.magnitudeResponseDB.map { $0.frequency }

                        // Compute predicted summation using current crossover and EQ configs
                        let measurements = Dictionary(uniqueKeysWithValues: store.transferFunctionDataset.channels
                            .filter(\.isMeasured).map { ($0.channelIndex, $0) })
                        let currentEQs = Dictionary(uniqueKeysWithValues: store.outputChannelMatrix.channels
                            .enumerated().map { ($0.offset, $0.element.eq) })
                        let channelDelays = Dictionary(uniqueKeysWithValues: store.outputChannelMatrix.channels
                            .enumerated().map { ($0.offset, Double($0.element.delayMs)) })

                        let predictedSummation = CrossoverOptimiser.computePredictedSummation(
                            measurements: measurements,
                            channelDelays: channelDelays,
                            crossoverConfig: store.activeCrossoverConfig,
                            eqConfigs: currentEQs,
                            frequencies: frequencies,
                            sampleRate: store.streamSampleRate
                        )

                        let deviationFromPrediction = computeRMSError(
                            measured: result.magnitudeResponseDB.map { ($0.frequency, $0.gainDB) },
                            target: predictedSummation,
                            frequencies: frequencies
                        )
                        let deviationFromTarget = computeRMSError(
                            measured: result.magnitudeResponseDB.map { ($0.frequency, $0.gainDB) },
                            target: optimisationParams.targetCurve,
                            frequencies: frequencies
                        )

                        Text("Deviation from prediction: ±\(String(format: "%.1f", deviationFromPrediction)) dB RMS (80 Hz – 10 kHz)")
                            .font(.caption)
                        Text("Deviation from target: ±\(String(format: "%.1f", deviationFromTarget)) dB RMS (80 Hz – 10 kHz)")
                            .font(.caption)
                    }

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

    // MARK: - Helper Functions

    private func listInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var devices: [(id: AudioDeviceID, name: String)] = []
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceIDs: [AudioDeviceID] = []
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return devices
        }

        deviceIDs = Array(repeating: AudioDeviceID(), count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return devices
        }

        for deviceID in deviceIDs {
            guard let nameStr = fetchStringProperty(id: deviceID, selector: kAudioObjectPropertyName),
                  !nameStr.isEmpty else { continue }

            var streamConfigAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufferSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(deviceID, &streamConfigAddress, 0, nil, &bufferSize) == noErr, bufferSize > 0 {
                devices.append((id: deviceID, name: nameStr))
            }
        }

        return devices
    }

    private func fetchStringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &propertyAddress, 0, nil, &dataSize) == noErr else {
            return nil
        }

        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(dataSize))
        defer { nameBuffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, nameBuffer) == noErr else {
            return nil
        }

        return String(cString: nameBuffer)
    }

    private func computeRMSError(
        measured: [(frequency: Double, gainDB: Double)],
        target: [(frequency: Double, gainDB: Double)],
        frequencies: [Double]
    ) -> Double {
        var sumSquared: Double = 0

        for f in frequencies {
            let measuredGain = measured.first(where: { abs($0.frequency - f) < 1.0 })?.gainDB ?? 0.0
            let targetGain = target.first(where: { abs($0.frequency - f) < 1.0 })?.gainDB ?? 0.0
            let error = measuredGain - targetGain
            sumSquared += error * error
        }

        return sqrt(sumSquared / Double(frequencies.count))
    }
}
