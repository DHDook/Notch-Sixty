// RTAView.swift
// Dual 31-band real-time spectrum analyser views + horizontal master meters.
// Features: peak/RMS horizontal bars, glowing clip indicators with 1.5 s hold
// and click-to-reset, FPS diagnostics panel, hover delta-gain tooltip.

import Combine
import SwiftUI

// MARK: - Meter Bridge

/// Bridges the MeterStore observer system to four normalised (0–1) level fractions
/// for the RTA horizontal master meter rows.
@MainActor
final class RTAMeterBridge: ObservableObject {
    @Published var inputPeakFraction:  Float = 0
    @Published var outputPeakFraction: Float = 0
    @Published var inputRmsFraction:   Float = 0
    @Published var outputRmsFraction:  Float = 0
    @Published var inputIsClipping:    Bool  = false
    @Published var outputIsClipping:   Bool  = false

    @Published var showDiagnostics: Bool = false

    private let ipL = RTASingleObserver(), ipR = RTASingleObserver()
    private let opL = RTASingleObserver(), opR = RTASingleObserver()
    private let irL = RTASingleObserver(), irR = RTASingleObserver()
    private let orL = RTASingleObserver(), orR = RTASingleObserver()

    /// Clip hold duration in seconds.
    private let clipHoldDuration: TimeInterval = 1.5
    private var inputClipTask:  Task<Void, Never>?
    private var outputClipTask: Task<Void, Never>?

    func register(with meterStore: MeterStore) {
        meterStore.addObserver(ipL, for: .inputPeakLeft)
        meterStore.addObserver(ipR, for: .inputPeakRight)
        meterStore.addObserver(opL, for: .outputPeakLeft)
        meterStore.addObserver(opR, for: .outputPeakRight)
        meterStore.addObserver(irL, for: .inputRMSLeft)
        meterStore.addObserver(irR, for: .inputRMSRight)
        meterStore.addObserver(orL, for: .outputRMSLeft)
        meterStore.addObserver(orR, for: .outputRMSRight)

        ipL.onUpdate = { [weak self] v, _, c in
            self?.inputPeakFraction = max(self?.inputPeakFraction ?? 0, v)
            if c { self?.triggerInputClip() }
        }
        ipR.onUpdate = { [weak self] v, _, _ in
            self?.inputPeakFraction = max(self?.inputPeakFraction ?? 0, v)
        }
        opL.onUpdate = { [weak self] v, _, c in
            self?.outputPeakFraction = max(self?.outputPeakFraction ?? 0, v)
            if c { self?.triggerOutputClip() }
        }
        opR.onUpdate = { [weak self] v, _, _ in
            self?.outputPeakFraction = max(self?.outputPeakFraction ?? 0, v)
        }
        irL.onUpdate = { [weak self] v, _, _ in self?.inputRmsFraction  = max(self?.inputRmsFraction  ?? 0, v) }
        irR.onUpdate = { [weak self] v, _, _ in self?.inputRmsFraction  = max(self?.inputRmsFraction  ?? 0, v) }
        orL.onUpdate = { [weak self] v, _, _ in self?.outputRmsFraction = max(self?.outputRmsFraction ?? 0, v) }
        orR.onUpdate = { [weak self] v, _, _ in self?.outputRmsFraction = max(self?.outputRmsFraction ?? 0, v) }
    }

    func manuallyResetClips() {
        inputClipTask?.cancel();  inputClipTask  = nil; inputIsClipping  = false
        outputClipTask?.cancel(); outputClipTask = nil; outputIsClipping = false
    }

    private func triggerInputClip() {
        guard !inputIsClipping else { return }
        inputIsClipping = true
        inputClipTask?.cancel()
        inputClipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(1_500_000_000))
            guard let self, !Task.isCancelled else { return }
            self.inputIsClipping = false
        }
    }

    private func triggerOutputClip() {
        guard !outputIsClipping else { return }
        outputIsClipping = true
        outputClipTask?.cancel()
        outputClipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(1_500_000_000))
            guard let self, !Task.isCancelled else { return }
            self.outputIsClipping = false
        }
    }
}

/// Minimal MeterObserver that forwards updates via a closure.
@MainActor
private final class RTASingleObserver: MeterObserver {
    var onUpdate: ((Float, Float, Bool) -> Void)?

    nonisolated func meterUpdated(value: Float, hold: Float, clipping: Bool) {
        let v = value, h = hold, c = clipping
        Task { @MainActor [weak self] in self?.onUpdate?(v, h, c) }
    }
}

// MARK: - Dashboard

/// Full dual-RTA dashboard: horizontal master level meters + dual 31-band spectrum canvases.
struct RTADashboardView: View {
    @ObservedObject var analyzer: AdvancedDualSpectrumAnalyzer
    @StateObject private var meterBridge = RTAMeterBridge()
    @EnvironmentObject private var store: EqualiserStore

    /// Hover state for delta-gain tooltip
    @State private var hoveredBandIndex: Int = -1
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        VStack(spacing: 4) {
            // Top zone: horizontal peak/RMS meters with clip indicators
            metersZone

            // Bottom zone: dual 31-band canvases
            HStack(spacing: 8) {
                rtaCanvas(
                    bands:     analyzer.inputBands,
                    showPeaks: analyzer.showInputPeaks,
                    barColour: .cyan.opacity(0.75),
                    label:     "Pre-EQ"
                )
                rtaCanvas(
                    bands:     analyzer.outputBands,
                    showPeaks: analyzer.showOutputPeaks,
                    barColour: .green.opacity(0.75),
                    label:     "Post-EQ"
                )
            }
            .frame(height: 128)
            .padding(.horizontal, 8)

            // Shared frequency axis labels
            FrequencyAxisLabels(bandCount: analyzer.centerFrequencies.count)
                .padding(.horizontal, 8)

            // Diagnostics panel (optional)
            if analyzer.showDiagnostics {
                HStack(spacing: 16) {
                    Text("FPS: \(analyzer.currentFps)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(analyzer.currentFps >= 18 ? .secondary : Color.orange)
                    Text("Bands: \(analyzer.centerFrequencies.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("SR: \(store.dynamicsConfig.advanced.latencyMode == .music ? "Music" : "Movie")")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
                .transition(.opacity)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onAppear {
            meterBridge.register(with: store.meterStore)
            store.wireRTAAnalyzer()
        }
    }

    // MARK: - Meters Zone

    private var metersZone: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                HStack(spacing: 20) {
                    HorizontalMasterMeterRow(
                        label: "IN",
                        peakFraction: meterBridge.inputPeakFraction,
                        rmsFraction:  meterBridge.inputRmsFraction,
                        isClipping:   meterBridge.inputIsClipping
                    )
                    HorizontalMasterMeterRow(
                        label: "OUT",
                        peakFraction: meterBridge.outputPeakFraction,
                        rmsFraction:  meterBridge.outputRmsFraction,
                        isClipping:   meterBridge.outputIsClipping
                    )
                }
                .padding(.horizontal, 8)

                Spacer()

                // Controls row: peak toggles, diagnostics, clip reset
                HStack(spacing: 10) {
                    Toggle("In Peaks", isOn: $analyzer.showInputPeaks)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 9))
                        .controlSize(.mini)
                    Toggle("Out Peaks", isOn: $analyzer.showOutputPeaks)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 9))
                        .controlSize(.mini)
                    Toggle("Diag", isOn: $analyzer.showDiagnostics)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 9))
                        .controlSize(.mini)

                    // Glowing clip indicator — click to reset
                    Button {
                        meterBridge.manuallyResetClips()
                    } label: {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(clipColour)
                                .frame(width: 7, height: 7)
                                .shadow(color: clipGlowColour, radius: clipGlowing ? 4 : 0)
                                .animation(.easeInOut(duration: 0.15), value: clipGlowing)
                            Text("CLIP")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(clipGlowing ? .red : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Hardware clip indicator — click to reset")
                }
                .padding(.trailing, 8)
            }
        }
    }

    private var clipGlowing: Bool { meterBridge.inputIsClipping || meterBridge.outputIsClipping }

    private var clipColour: Color {
        clipGlowing ? .red : Color.secondary.opacity(0.4)
    }

    private var clipGlowColour: Color {
        clipGlowing ? .red.opacity(0.8) : .clear
    }

    // MARK: - RTA Canvas

    @ViewBuilder
    private func rtaCanvas(
        bands: [BandData],
        showPeaks: Bool,
        barColour: Color,
        label: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            BackgroundGridLines(minDb: analyzer.minDb, maxDb: analyzer.maxDb)

            Canvas { ctx, size in
                let count = bands.count
                guard count > 0 else { return }
                let barW = size.width  / CGFloat(count)
                let gap  = barW * 0.20

                for i in 0..<count {
                    let norm = CGFloat(analyzer.normaliseDb(bands[i].currentValue))
                    let h    = max(1, norm * size.height)
                    let rect = CGRect(
                        x:      CGFloat(i) * barW + gap / 2,
                        y:      size.height - h,
                        width:  barW - gap,
                        height: h
                    )
                    ctx.fill(Path(rect), with: .color(barColour))

                    if showPeaks {
                        let pNorm = CGFloat(analyzer.normaliseDb(bands[i].peakValue))
                        if pNorm > 0 {
                            let py = max(0, size.height - pNorm * size.height - 1.5)
                            let pr = CGRect(x: CGFloat(i) * barW + gap / 2, y: py,
                                           width: barW - gap, height: 2)
                            ctx.fill(Path(pr), with: .color(.white.opacity(0.80)))
                        }
                    }

                    // Highlight hovered band
                    if i == hoveredBandIndex {
                        let highlight = CGRect(x: CGFloat(i) * barW + gap / 2, y: 0,
                                              width: barW - gap, height: size.height)
                        ctx.fill(Path(highlight), with: .color(.white.opacity(0.06)))
                    }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                case .ended:
                    hoveredBandIndex = -1
                }
            }
            .onChange(of: hoverLocation) { _, loc in
                let count = analyzer.centerFrequencies.count
                guard count > 0 else { return }
                // Canvas fills its parent; approximate band index from x position
                let estimatedWidth = 400.0  // will be close enough for tooltip snapping
                let barW = estimatedWidth / Double(count)
                let idx = min(count - 1, max(0, Int(loc.x / barW)))
                hoveredBandIndex = idx
            }

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 2)

            // Delta-gain tooltip
            if hoveredBandIndex >= 0 && hoveredBandIndex < analyzer.inputBands.count {
                let inDb  = analyzer.inputBands[hoveredBandIndex].currentValue
                let outDb = analyzer.outputBands[hoveredBandIndex].currentValue
                let delta = outDb - inDb
                let freq  = analyzer.centerFrequencies[hoveredBandIndex]
                let freqLabel = freq >= 1000 ? String(format: "%.1f kHz", freq / 1000) : String(format: "%.0f Hz", freq)
                let sign  = delta >= 0 ? "+" : ""

                Text("\(freqLabel)  Δ\(sign)\(String(format: "%.1f", delta)) dB")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.72))
                    .cornerRadius(3)
                    .padding(.top, 2)
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black.opacity(0.22))
        .cornerRadius(4)
    }
}

// MARK: - Horizontal Master Meter Row

struct HorizontalMasterMeterRow: View {
    let label:        String
    let peakFraction: Float
    let rmsFraction:  Float
    let isClipping:   Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(isClipping ? .red : .secondary)
                .frame(width: 26, alignment: .trailing)

            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(peakColour)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, peakFraction))))
                    }
                }
                .frame(height: 5)
                .animation(.linear(duration: 0.04), value: peakFraction)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.10))
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, rmsFraction))))
                    }
                }
                .frame(height: 3)
                .animation(.linear(duration: 0.08), value: rmsFraction)
            }
        }
    }

    private var peakColour: Color {
        if isClipping          { return .red    }
        if peakFraction > 0.90 { return .orange }
        if peakFraction > 0.70 { return .yellow }
        return .green
    }
}

// MARK: - Background Grid Lines

struct BackgroundGridLines: View {
    let minDb: Float
    let maxDb: Float

    private let referenceLines: [Float] = [0, -10, -20, -30, -40, -50]

    var body: some View {
        Canvas { ctx, size in
            let range = maxDb - minDb
            for db in referenceLines {
                let norm = CGFloat((db - minDb) / range)
                let y    = size.height - norm * size.height
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(
                    path,
                    with: .color(.secondary.opacity(db == 0 ? 0.35 : 0.14)),
                    style: StrokeStyle(
                        lineWidth: db == 0 ? 0.75 : 0.5,
                        dash: db == 0 ? [] : [3, 3]
                    )
                )
            }
        }
    }
}

// MARK: - Frequency Axis Labels

struct FrequencyAxisLabels: View {
    let bandCount: Int

    private let labels: [(text: String, index: Int)] = [
        ("20", 0), ("100", 7), ("1k", 17), ("10k", 27), ("20k", 30)
    ]

    var body: some View {
        GeometryReader { geo in
            let totalBands = max(bandCount - 1, 1)
            ForEach(labels, id: \.text) { item in
                let x = (CGFloat(item.index) / CGFloat(totalBands)) * geo.size.width
                Text(item.text)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .position(x: x, y: geo.size.height / 2)
            }
        }
        .frame(height: 12)
    }
}
