import SwiftUI
import CoreAudio

// MARK: - Multi-Channel Measurement View

/// UI for multi-channel transfer function measurement with channel selection,
/// progress display, and results review.
struct MultiChannelMeasurementView: View {
    @EnvironmentObject var store: EqualiserStore

    // Selection state
    @State private var selectedChannelIndices: Set<Int> = []
    @State private var selectedMicID: AudioDeviceID? = nil
    @State private var availableMics: [(id: AudioDeviceID, name: String)] = []
    @State private var micPositionCount: Int = 1
    @State private var sweepsPerPosition: Int = 3
    @State private var sweepDurationSeconds: Double = 10.0
    @State private var minSNRDB: Double = 30.0

    // UI state
    @State private var showAdvanced = false
    @State private var showingResonanceView = false
    @State private var selectedChannelForResonance: Int = 0
    @State private var measurementTask: Task<Void, Never>?
    @State private var measurementMode: MeasurementMode = .individual
    @State private var showComparisonOverlay = false
    @State private var showingSavePresetSheet = false
    @State private var showingDeletePresetSheet = false
    @State private var showingRenamePresetSheet = false
    @State private var presetToDelete: String?
    @State private var presetToRename: String?

    enum MeasurementMode: String, CaseIterable {
        case individual = "Individual"
        case combined = "Combined"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.tfMeasurementStep {
            case .idle:
                idleView
            case .preparingChannel(let channelIndex, let label):
                progressView(text: "Preparing \(label)…", channelIndex: channelIndex)
            case .awaitingMicPosition(let positionIndex, let totalPositions):
                awaitingMicPositionView(positionIndex: positionIndex, totalPositions: totalPositions)
            case .playingSweep(let channelIndex, let label, let sweepIndex, let totalSweeps, let positionIndex, let progress):
                playingSweepView(channelIndex: channelIndex, label: label, sweepIndex: sweepIndex, totalSweeps: totalSweeps, positionIndex: positionIndex, progress: progress)
            case .computingIR(let channelIndex, let label):
                progressView(text: "Computing response for \(label)…", channelIndex: channelIndex)
            case .channelComplete(let channelIndex, let label, let snrDB):
                channelCompleteView(channelIndex: channelIndex, label: label, snrDB: snrDB)
            case .allChannelsComplete:
                resultsView
            case .failed(let channelIndex, let reason):
                failedView(channelIndex: channelIndex, reason: reason)
            }
        }
        .onChange(of: store.tfMeasurementStep) { _, newValue in
            // Clean up task when measurement completes
            if case .idle = newValue {
                measurementTask = nil
            }
        }
        .onAppear {
            availableMics = listInputDevices()
        }
        .sheet(isPresented: $showingSavePresetSheet) {
            SaveMultiChannelCorrectionPresetSheet()
        }
        .sheet(isPresented: $showingDeletePresetSheet) {
            if let presetName = presetToDelete {
                DeleteMultiChannelCorrectionPresetSheet(presetName: presetName)
            }
        }
        .sheet(isPresented: $showingRenamePresetSheet) {
            if let oldName = presetToRename {
                RenameMultiChannelCorrectionPresetSheet(oldName: oldName)
            }
        }
    }

    // MARK: - Idle View (Selection Controls)

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Measurement mode selector
            Picker("Measurement mode", selection: $measurementMode) {
                ForEach(MeasurementMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            // Channel selection
            VStack(alignment: .leading, spacing: 8) {
                Text(measurementMode == .individual ? "Select channels to measure" : "Select channels to play together")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Main Chain option
                Toggle("Main Chain", isOn: Binding(
                    get: { selectedChannelIndices.contains(-1) },
                    set: { isOn in
                        if isOn {
                            selectedChannelIndices.insert(-1)
                        } else {
                            selectedChannelIndices.remove(-1)
                        }
                    }
                ))

                // Output channels
                ForEach(Array(store.outputChannelMatrix.channels.enumerated()), id: \.element.id) { index, channel in
                    Toggle(channel.source.displayName, isOn: Binding(
                        get: { selectedChannelIndices.contains(index) },
                        set: { isOn in
                            if isOn {
                                selectedChannelIndices.insert(index)
                            } else {
                                selectedChannelIndices.remove(index)
                            }
                        }
                    ))
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Mic device selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Microphone input device")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if availableMics.isEmpty {
                    Text("No input devices found.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Picker("Input Microphone", selection: $selectedMicID) {
                        Text("None selected").tag(Optional<AudioDeviceID>.none)
                        ForEach(availableMics, id: \.id) { mic in
                            Text(mic.name).tag(Optional(mic.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }

            // Position and sweep settings
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mic positions: \(micPositionCount)")
                        .font(.caption)
                        Stepper("", value: $micPositionCount, in: 1...5)
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sweeps per position: \(sweepsPerPosition)")
                        .font(.caption)
                    Stepper("", value: $sweepsPerPosition, in: 1...5)
                        .frame(width: 80)
                }
            }

            // Advanced settings
            DisclosureGroup("Advanced settings", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sweep duration:")
                            .font(.caption)
                        Slider(value: $sweepDurationSeconds, in: 5.0...30.0, step: 1.0)
                        Text("\(Int(sweepDurationSeconds)) s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                    }

                    HStack {
                        Text("Min SNR:")
                            .font(.caption)
                        Slider(value: $minSNRDB, in: 20.0...50.0, step: 5.0)
                        Text("\(Int(minSNRDB)) dB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 35)
                    }
                }
                .padding(.top, 8)
            }

            // Start button
            Button(measurementMode == .individual ? "Measure Individually" : "Measure Combined") {
                startMeasurement()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedChannelIndices.isEmpty || selectedMicID == nil)
        }
    }

    // MARK: - Progress Views

    private func progressView(text: String, channelIndex: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func awaitingMicPositionView(positionIndex: Int, totalPositions: Int) -> some View {
        VStack(spacing: 12) {
            Text("Place the microphone at position \(positionIndex + 1) of \(totalPositions), then continue.")
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Continue") {
                    store.confirmMicPositioned()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    cancelMeasurement()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func playingSweepView(channelIndex: Int, label: String, sweepIndex: Int, totalSweeps: Int, positionIndex: Int, progress: Double) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Playing sweep \(sweepIndex + 1)/\(totalSweeps) for \(label)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Position \(positionIndex + 1)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func channelCompleteView(channelIndex: Int, label: String, snrDB: Double) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(snrDB >= 30.0 ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text("\(label) complete — SNR: \(String(format: "%.1f", snrDB)) dB")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func failedView(channelIndex: Int, reason: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text("Measurement failed: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Return to selection") {
                // Reset to idle state - this would need store support
                // For now, the user would need to restart the app
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Measurement complete")
                    .font(.headline)

                Spacer()

                // Preset controls
                MultiChannelCorrectionPresetPicker()
                Button("Save Preset") {
                    showingSavePresetSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let selectedPreset = store.multiChannelCorrectionPresetManager.selectedPresetName {
                    Menu {
                        Button("Rename") {
                            presetToRename = selectedPreset
                            showingRenamePresetSheet = true
                        }
                        Button("Delete", role: .destructive) {
                            presetToDelete = selectedPreset
                            showingDeletePresetSheet = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if measurementMode == .combined {
                // Combined measurement results
                if let combined = store.combinedMeasurementResult {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Combined response")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        // Combined magnitude response
                        MagnitudeResponseCurveView(
                            measuredResponse: combined.magnitudeResponseDB.map { ($0.frequency, $0.gainDB) },
                            targetCurve: store.targetCurve,
                            comparisonResponse: showComparisonOverlay && combined.individualMeasurements != nil ? sumIndividualResponses() : nil
                        )
                        .frame(height: 150)

                        // Comparison toggle
                        if combined.individualMeasurements != nil {
                            Toggle("Show comparison (sum of individual responses)", isOn: $showComparisonOverlay)
                                .controlSize(.small)
                        }

                        Divider()

                        Button("Start new measurement") {
                            resetMeasurement()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("No combined measurement data available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Individual measurement results
                if store.transferFunctionDataset.channels.isEmpty {
                    Text("No measurement data available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.transferFunctionDataset.channels) { channel in
                            ChannelResultCard(
                                channel: channel,
                                minSNRDB: minSNRDB,
                                onResonanceClick: {
                                    selectedChannelForResonance = channel.channelIndex
                                    showingResonanceView = true
                                }
                            )
                        }
                    }

                    Divider()

                    Button("Start new measurement") {
                        resetMeasurement()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showingResonanceView) {
            ResonanceDetectionView(channelIndex: selectedChannelForResonance)
                .environmentObject(store)
        }
    }

    /// Sums individual channel complex responses to create a comparison curve.
    /// This is the expected response if channels summed perfectly without phase cancellation.
    private func sumIndividualResponses() -> [(frequency: Double, gainDB: Double)] {
        guard let dataset = store.combinedMeasurementResult?.individualMeasurements,
              !dataset.channels.isEmpty else { return [] }

        // Find the frequency grid from the first channel
        guard let firstFreqGrid = dataset.channels.first?.averagedComplexResponse else { return [] }

        var summedReal: [Double] = Array(repeating: 0.0, count: firstFreqGrid.count)
        var summedImag: [Double] = Array(repeating: 0.0, count: firstFreqGrid.count)

        // Sum complex responses across all channels
        for channel in dataset.channels {
            guard let complexResponse = channel.averagedComplexResponse else { continue }
            for (index, point) in complexResponse.enumerated() {
                if index < summedReal.count {
                    summedReal[index] += point.real
                    summedImag[index] += point.imag
                }
            }
        }

        // Convert summed complex response to magnitude in dB
        return firstFreqGrid.enumerated().map { index, point in
            let real = summedReal[index]
            let imag = summedImag[index]
            let magnitude = sqrt(real * real + imag * imag)
            let gainDB = magnitude > 0 ? 20.0 * log10(magnitude) : -100.0
            return (frequency: point.frequency, gainDB: gainDB)
        }
    }

    // MARK: - Actions

    private func startMeasurement() {
        guard let micID = selectedMicID else { return }
        let indices = Array(selectedChannelIndices).sorted()

        measurementTask = Task {
            if measurementMode == .individual {
                await store.runTransferFunctionMeasurement(
                    micInputDeviceID: micID,
                    channelIndices: indices,
                    micPositionCount: micPositionCount,
                    sweepsPerPosition: sweepsPerPosition,
                    sweepDurationSeconds: sweepDurationSeconds,
                    minSNRDB: minSNRDB
                )
            } else {
                await store.runCombinedMeasurement(
                    micInputDeviceID: micID,
                    channelIndices: indices,
                    sweepDurationSeconds: sweepDurationSeconds
                )
            }
        }
    }

    private func cancelMeasurement() {
        measurementTask?.cancel()
        measurementTask = nil
        // Reset to idle state
        store.tfMeasurementStep = .idle
    }

    private func resetMeasurement() {
        store.tfMeasurementStep = .idle
        store.transferFunctionDataset = TransferFunctionDataset()
        selectedChannelIndices.removeAll()
    }

    // MARK: - Input Device Enumeration

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
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.stride)
            if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr {
                let nameStr = name as String
                guard !nameStr.isEmpty else { continue }

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
        }

        return devices
    }
}

// MARK: - Channel Result Card

private struct ChannelResultCard: View {
    @EnvironmentObject var store: EqualiserStore
    let channel: ChannelTransferFunctionData
    let minSNRDB: Double
    let onResonanceClick: () -> Void

    @State private var maxBands: Int = 16
    @State private var correctionMode: CorrectionMode = .iirParametric
    @State private var tapCount: Int = 4096
    @State private var showingApplyWarning = false
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(channel.channelLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // SNR indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(snrColor)
                        .frame(width: 6, height: 6)
                    Text("SNR: \(String(format: "%.1f", channelSNR)) dB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Magnitude response display
            if !channelMagnitudeResponse.isEmpty {
                MagnitudeResponseCurveView(
                    measuredResponse: channelMagnitudeResponse,
                    targetCurve: store.targetCurve,
                    comparisonResponse: nil
                )
                .frame(height: 120)
            } else {
                Text("No magnitude response data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 120)
            }

            // Correction controls
            VStack(alignment: .leading, spacing: 8) {
                // Correction mode picker
                Picker("Correction mode", selection: $correctionMode) {
                    ForEach(CorrectionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)

                // Mode-specific controls
                if correctionMode == .iirParametric {
                    // Max bands control
                    HStack(spacing: 8) {
                        Text("Max bands:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper("", value: $maxBands, in: 8...20)
                            .frame(width: 80)
                        Text("\(maxBands)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                    }
                } else {
                    // Tap count control for FIR modes
                    HStack(spacing: 8) {
                        Text("Taps:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $tapCount) {
                            Text("512").tag(512)
                            Text("1024").tag(1024)
                            Text("2048").tag(2048)
                            Text("4096").tag(4096)
                            Text("8192").tag(8192)
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)

                        // Display latency
                        let sr = store.transferFunctionDataset.sampleRate
                        let latencyMs = Double(tapCount) / sr * 1000.0
                        Text("(\(String(format: "%.1f", latencyMs)) ms)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Action buttons
                HStack(spacing: 8) {
                    Button("View Resonances") {
                        onResonanceClick()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(applyButtonText) {
                        if channelHasExistingEQ {
                            showingApplyWarning = true
                        } else {
                            applyCorrection()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isApplying || channel.channelIndex == -1 || !channel.isMeasured)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .alert("Replace Existing EQ?", isPresented: $showingApplyWarning) {
            Button("Cancel", role: .cancel) {
                showingApplyWarning = false
            }
            Button("Replace") {
                showingApplyWarning = false
                applyCorrection()
            }
        } message: {
            Text("This channel has \(existingBandCount) existing EQ band(s). Applying correction will replace them with the measured correction bands. Continue?")
        }
    }

    private var channelHasExistingEQ: Bool {
        guard channel.channelIndex >= 0,
              channel.channelIndex < store.outputChannelMatrix.channels.count else { return false }
        return store.outputChannelMatrix.channels[channel.channelIndex].eq.activeBandCount > 0
    }

    private var existingBandCount: Int {
        guard channel.channelIndex >= 0,
              channel.channelIndex < store.outputChannelMatrix.channels.count else { return 0 }
        return store.outputChannelMatrix.channels[channel.channelIndex].eq.activeBandCount
    }

    private var applyButtonText: String {
        switch correctionMode {
        case .iirParametric:
            return "Apply IIR Correction"
        case .firMinimumPhase:
            return "Apply FIR Correction"
        case .firWithPhaseCorrection:
            return "Apply FIR + Phase"
        }
    }

    private func applyCorrection() {
        isApplying = true
        switch correctionMode {
        case .iirParametric:
            store.applyIIRCorrectionToChannel(channel.channelIndex, maxBands: maxBands)
        case .firMinimumPhase:
            store.applyFIRCorrectionToChannel(channel.channelIndex, withPhaseCorrection: false, tapCount: tapCount)
        case .firWithPhaseCorrection:
            store.applyFIRCorrectionToChannel(channel.channelIndex, withPhaseCorrection: true, tapCount: tapCount)
        }
        // Reset after a short delay to show the action completed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isApplying = false
        }
    }

    private var channelSNR: Double {
        // Calculate SNR from the averaged impulse response
        guard let ir = channel.averagedIR, !ir.isEmpty else { return 0.0 }
        let sampleRate = store.transferFunctionDataset.sampleRate
        return RoomCorrectionEngine.estimateSNR(ir: ir, sampleRate: sampleRate)
    }

    private var channelMagnitudeResponse: [(frequency: Double, gainDB: Double)] {
        guard let magnitude = channel.averagedMagnitudeDB else { return [] }
        return magnitude.map { ($0.frequency, $0.gainDB) }
    }

    private var snrColor: Color {
        let snr = channelSNR
        if snr >= minSNRDB {
            return .green
        } else if snr >= minSNRDB - 10 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Magnitude Response Curve View

private struct MagnitudeResponseCurveView: View {
    let measuredResponse: [(frequency: Double, gainDB: Double)]
    let targetCurve: [(frequency: Double, gainDB: Double)]
    let comparisonResponse: [(frequency: Double, gainDB: Double)]?

    private let plotHeight: CGFloat = 120
    private let maxDB: Double = 15
    private let freqMin: Double = 20
    private let freqMax: Double = 20_000

    var body: some View {
        Canvas { context, size in
            drawBackground(context: context, size: size)
            drawGrid(context: context, size: size)
            drawFreqLabels(context: context, size: size)
            if !measuredResponse.isEmpty {
                drawMeasuredCurve(context: context, size: size)
            }
            if let comparison = comparisonResponse, !comparison.isEmpty {
                drawComparisonCurve(context: context, size: size)
            }
            drawZeroLine(context: context, size: size)
        }
        .frame(height: plotHeight)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(4)
    }

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(NSColor.textBackgroundColor)))
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let padding: CGFloat = 40
        let plotWidth = size.width - 2 * padding
        let plotHeight = size.height - 2 * padding

        // Horizontal grid lines (dB)
        for db in stride(from: -maxDB, through: maxDB, by: 5) {
            let y = padding + CGFloat((maxDB - db) / (2 * maxDB)) * plotHeight
            context.stroke(Path { path in
                path.move(to: CGPoint(x: padding, y: y))
                path.addLine(to: CGPoint(x: size.width - padding, y: y))
            }, with: .color(.secondary.opacity(0.3)))
        }

        // Vertical grid lines (frequency)
        let freqs = [100, 1000, 10000]
        for freq in freqs {
            let freqDouble = Double(freq)
            let logRatio = log10(freqDouble / freqMin) / log10(freqMax / freqMin)
            let x = padding + CGFloat(logRatio) * plotWidth
            context.stroke(Path { path in
                path.move(to: CGPoint(x: x, y: padding))
                path.addLine(to: CGPoint(x: x, y: size.height - padding))
            }, with: .color(.secondary.opacity(0.3)))
        }
    }

    private func drawFreqLabels(context: GraphicsContext, size: CGSize) {
        let padding: CGFloat = 40
        let plotWidth = size.width - 2 * padding

        let freqs = [100, 1000, 10000]
        for freq in freqs {
            let freqDouble = Double(freq)
            let logRatio = log10(freqDouble / freqMin) / log10(freqMax / freqMin)
            let x = padding + CGFloat(logRatio) * plotWidth
            let label = freq >= 1000 ? "\(freq / 1000)k" : "\(freq)"
            context.draw(Text(label).font(.caption2), at: CGPoint(x: x - 10, y: size.height - padding + 5))
        }
    }

    private func drawMeasuredCurve(context: GraphicsContext, size: CGSize) {
        let padding: CGFloat = 40
        let plotWidth = size.width - 2 * padding
        let plotHeight = size.height - 2 * padding

        var path = Path()
        for (index, point) in measuredResponse.enumerated() {
            let logRatio = log10(point.frequency / freqMin) / log10(freqMax / freqMin)
            let x = padding + CGFloat(logRatio) * plotWidth
            let y = padding + CGFloat((maxDB - point.gainDB) / (2 * maxDB)) * plotHeight

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.blue), lineWidth: 2)
    }

    private func drawComparisonCurve(context: GraphicsContext, size: CGSize) {
        guard let comparison = comparisonResponse else { return }
        let padding: CGFloat = 40
        let plotWidth = size.width - 2 * padding
        let plotHeight = size.height - 2 * padding

        var path = Path()
        for (index, point) in comparison.enumerated() {
            let logRatio = log10(point.frequency / freqMin) / log10(freqMax / freqMin)
            let x = padding + CGFloat(logRatio) * plotWidth
            let y = padding + CGFloat((maxDB - point.gainDB) / (2 * maxDB)) * plotHeight

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.green.opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
    }

    private func drawZeroLine(context: GraphicsContext, size: CGSize) {
        let padding: CGFloat = 40
        let plotHeight = size.height - 2 * padding
        let zeroY = padding + plotHeight / 2

        context.stroke(Path { path in
            path.move(to: CGPoint(x: padding, y: zeroY))
            path.addLine(to: CGPoint(x: size.width - padding, y: zeroY))
        }, with: .color(.secondary))
    }
}

#Preview {
    MultiChannelMeasurementView()
        .environmentObject(EqualiserStore())
}
