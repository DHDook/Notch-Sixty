// RTAView.swift
// Unified 31-band real-time spectrum analyser + horizontal master level meters.
// Unified canvas: input bars (0.4 opacity) + output bars (full opacity, grayed on bypass),
// multi-colour gradient fills, bypass-aware background/target-line, clip indicators,
// diagnostics, hover delta-gain tooltip.

import Combine
import SwiftUI

// MARK: - Meter Bridge

/// Bridges the MeterStore observer system to four normalised (0–1) level fractions.
/// Stores L and R channels separately so the combined max decays correctly each frame.
@MainActor
final class RTAMeterBridge: ObservableObject {
    @Published var inputPeakFraction:  Float = 0
    @Published var outputPeakFraction: Float = 0
    @Published var inputRmsFraction:   Float = 0
    @Published var outputRmsFraction:  Float = 0
    @Published var inputIsClipping:    Bool  = false
    @Published var outputIsClipping:   Bool  = false

    // Per-channel storage — combined max is recomputed on every update so fractions decay.
    private var inputPeakL:  Float = 0, inputPeakR:  Float = 0
    private var outputPeakL: Float = 0, outputPeakR: Float = 0
    private var inputRmsL:   Float = 0, inputRmsR:   Float = 0
    private var outputRmsL:  Float = 0, outputRmsR:  Float = 0

    private let ipL = RTASingleObserver(), ipR = RTASingleObserver()
    private let opL = RTASingleObserver(), opR = RTASingleObserver()
    private let irL = RTASingleObserver(), irR = RTASingleObserver()
    private let orL = RTASingleObserver(), orR = RTASingleObserver()

    private let clipHoldNs: UInt64 = 1_500_000_000
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
            guard let self else { return }
            self.inputPeakL = v
            self.inputPeakFraction = max(self.inputPeakL, self.inputPeakR)
            if c { self.triggerInputClip() }
        }
        ipR.onUpdate = { [weak self] v, _, _ in
            guard let self else { return }
            self.inputPeakR = v
            self.inputPeakFraction = max(self.inputPeakL, self.inputPeakR)
        }
        opL.onUpdate = { [weak self] v, _, c in
            guard let self else { return }
            self.outputPeakL = v
            self.outputPeakFraction = max(self.outputPeakL, self.outputPeakR)
            if c { self.triggerOutputClip() }
        }
        opR.onUpdate = { [weak self] v, _, _ in
            guard let self else { return }
            self.outputPeakR = v
            self.outputPeakFraction = max(self.outputPeakL, self.outputPeakR)
        }
        irL.onUpdate = { [weak self] v, _, _ in
            guard let self else { return }
            self.inputRmsL = v
            self.inputRmsFraction = max(self.inputRmsL, self.inputRmsR)
        }
        irR.onUpdate = { [weak self] v, _, _ in
            guard let self else { return }
            self.inputRmsR = v
            self.inputRmsFraction = max(self.inputRmsL, self.inputRmsR)
        }
        orL.onUpdate = { [weak self] v, _, _ in
            guard let self else { return }
            self.outputRmsL = v
            self.outputRmsFraction = max(self.outputRmsL, self.outputRmsR)
        }
        orR.onUpdate = { [weak self] v, _, _ in
            guard let self else { return }
            self.outputRmsR = v
            self.outputRmsFraction = max(self.outputRmsL, self.outputRmsR)
        }
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
            try? await Task.sleep(nanoseconds: self?.clipHoldNs ?? 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.inputIsClipping = false
        }
    }

    private func triggerOutputClip() {
        guard !outputIsClipping else { return }
        outputIsClipping = true
        outputClipTask?.cancel()
        outputClipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.clipHoldNs ?? 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.outputIsClipping = false
        }
    }
}

// MARK: - Single Observer

@MainActor
private final class RTASingleObserver: MeterObserver {
    var onUpdate: ((Float, Float, Bool) -> Void)?

    nonisolated func meterUpdated(value: Float, hold: Float, clipping: Bool) {
        let v = value, h = hold, c = clipping
        Task { @MainActor [weak self] in self?.onUpdate?(v, h, c) }
    }
}

// MARK: - Dashboard

/// Unified RTA dashboard: horizontal master meter rows + single 31-band unified spectrum canvas.
struct RTADashboardView: View {
    @ObservedObject var analyzer: AdvancedDualSpectrumAnalyzer
    @StateObject private var meterBridge = RTAMeterBridge()
    @EnvironmentObject private var store: EqualiserStore

    @State private var hoveredBandIndex: Int = -1
    @State private var hoverLocation: CGPoint = .zero

    // Live spectrum gradient — anchored to full canvas height so bar colour maps correctly.
    private let liveGradient = Gradient(stops: [
        .init(color: .green,  location: 0.00),
        .init(color: .green,  location: 0.65),
        .init(color: .yellow, location: 0.82),
        .init(color: .orange, location: 0.92),
        .init(color: .red,    location: 1.00)
    ])

    private let bypassGradient = Gradient(stops: [
        .init(color: Color(white: 0.35, opacity: 0.35), location: 0.0),
        .init(color: Color(white: 0.90, opacity: 0.15), location: 1.0)
    ])

    private var isBypassed: Bool { store.isBypassed }

    var body: some View {
        VStack(spacing: 4) {
            metersZone
            spectrumZone
            FrequencyAxisLabels(bandCount: analyzer.centerFrequencies.count)
                .padding(.horizontal, 8)
            if analyzer.showDiagnostics {
                diagnosticsPanel
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onAppear {
            meterBridge.register(with: store.meterStore)
            store.wireRTAAnalyzer()
        }
    }

    // MARK: - Spectrum Zone

    private var spectrumZone: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                BackgroundGridLines(minDb: analyzer.minDb, maxDb: analyzer.maxDb)
                    .opacity(isBypassed ? 0.20 : 1.0)

                let bandCount   = analyzer.centerFrequencies.count
                let inputBands  = analyzer.inputBands
                let outputBands = analyzer.outputBands
                let targetPts   = analyzer.targetLinePoints
                let showIn      = analyzer.showInputPeaks
                let showOut     = analyzer.showOutputPeaks
                let bypassed    = isBypassed
                let hovered     = hoveredBandIndex
                let livGrad     = liveGradient
                let byGrad      = bypassGradient

                Canvas { ctx, size in
                    let count = bandCount
                    guard count > 0 else { return }
                    let sp: CGFloat = 2
                    let barW = (size.width - sp * CGFloat(count - 1)) / CGFloat(count)

                    // Layer A — Input bars (0.4 opacity)
                    ctx.opacity = 0.4
                    for i in 0..<count {
                        let norm = CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(
                            inputBands[i].currentValue, min: -60, max: 12))
                        let h = max(1, norm * size.height)
                        let x = CGFloat(i) * (barW + sp)
                        let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                        ctx.fill(Path(rect), with: .linearGradient(
                            livGrad,
                            startPoint: CGPoint(x: x, y: size.height),
                            endPoint:   CGPoint(x: x, y: 0)
                        ))
                    }

                    // Layer B — Output bars (full opacity; grayed when bypassed)
                    ctx.opacity = 1.0
                    for i in 0..<count {
                        let norm = CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(
                            outputBands[i].currentValue, min: -60, max: 12))
                        let h = max(1, norm * size.height)
                        let x = CGFloat(i) * (barW + sp)
                        let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                        ctx.fill(Path(rect), with: .linearGradient(
                            bypassed ? byGrad : livGrad,
                            startPoint: CGPoint(x: x, y: size.height),
                            endPoint:   CGPoint(x: x, y: 0)
                        ))
                    }

                    // Layer C — Output peak indicators (red ≥ 0 dB, yellow < 0 dB)
                    if showOut && !bypassed {
                        for i in 0..<count {
                            let pNorm = CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(
                                outputBands[i].peakValue, min: -60, max: 12))
                            guard pNorm > 0 else { continue }
                            let py = max(0, size.height - pNorm * size.height - 1.5)
                            let x  = CGFloat(i) * (barW + sp)
                            let pr = CGRect(x: x, y: py, width: barW, height: 2)
                            let col: Color = outputBands[i].peakValue >= 0.0 ? .red : .yellow
                            ctx.fill(Path(pr), with: .color(col))
                        }
                    }

                    // Layer C — Input peak indicators (white, dimmed)
                    if showIn {
                        for i in 0..<count {
                            let pNorm = CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(
                                inputBands[i].peakValue, min: -60, max: 12))
                            guard pNorm > 0 else { continue }
                            let py = max(0, size.height - pNorm * size.height - 1.5)
                            let x  = CGFloat(i) * (barW + sp)
                            let pr = CGRect(x: x, y: py, width: barW, height: 2)
                            ctx.fill(Path(pr), with: .color(.white.opacity(0.45)))
                        }
                    }

                    // Hovered band highlight
                    if hovered >= 0 && hovered < count {
                        let x = CGFloat(hovered) * (barW + sp)
                        ctx.fill(Path(CGRect(x: x, y: 0, width: barW, height: size.height)),
                                 with: .color(.white.opacity(0.06)))
                    }

                    // Layer D — Target curve (orange-pink when live, dashed gray on bypass)
                    guard !targetPts.isEmpty, targetPts.count == count else { return }
                    var tPath = Path()
                    for i in 0..<count {
                        let normY = bypassed
                            ? CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(0.0, min: -60, max: 12))
                            : CGFloat(targetPts[i])
                        let xPos = CGFloat(i) * (barW + sp) + barW / 2
                        let yPos = size.height - size.height * normY
                        if i == 0 { tPath.move(to: CGPoint(x: xPos, y: yPos)) }
                        else       { tPath.addLine(to: CGPoint(x: xPos, y: yPos)) }
                    }
                    if bypassed {
                        ctx.stroke(tPath, with: .color(.gray.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                    } else {
                        ctx.stroke(tPath, with: .linearGradient(
                            Gradient(colors: [.orange, .pink]),
                            startPoint: CGPoint(x: 0, y: size.height / 2),
                            endPoint:   CGPoint(x: size.width, y: size.height / 2)
                        ), style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round))
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc): hoverLocation = loc
                    case .ended:           hoveredBandIndex = -1
                    }
                }
                .onChange(of: hoverLocation) { _, loc in
                    let count = analyzer.centerFrequencies.count
                    guard count > 0 else { return }
                    let sp: CGFloat = 2
                    let barW = (geo.size.width - sp * CGFloat(count - 1)) / CGFloat(count)
                    hoveredBandIndex = min(count - 1, max(0, Int(loc.x / (barW + sp))))
                }

                // Legend (top-right overlay)
                spectrumLegend

                // Hover tooltip
                if hoveredBandIndex >= 0 && hoveredBandIndex < analyzer.inputBands.count {
                    hoverTooltip(for: hoveredBandIndex)
                }
            }
            .background(Color(white: 0.03))
            .cornerRadius(6)
        }
        .frame(height: 160)
        .padding(.horizontal, 8)
    }

    // MARK: - Legend

    private var spectrumLegend: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LinearGradient(colors: [.green, .yellow], startPoint: .bottom, endPoint: .top))
                .frame(width: 6, height: 6)
                .opacity(0.55)
            Text("Pre-EQ")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            Circle()
                .fill(LinearGradient(colors: [.green, .yellow], startPoint: .bottom, endPoint: .top))
                .frame(width: 6, height: 6)
            Text("Post-EQ")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            if !isBypassed && !analyzer.targetLinePoints.isEmpty {
                Rectangle()
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 12, height: 2)
                    .cornerRadius(1)
                Text("Target")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.50))
        .cornerRadius(3)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    // MARK: - Hover Tooltip

    @ViewBuilder
    private func hoverTooltip(for index: Int) -> some View {
        let inDb    = analyzer.inputBands[index].currentValue
        let outDb   = analyzer.outputBands[index].currentValue
        let delta   = outDb - inDb
        let freq    = analyzer.centerFrequencies[index]
        let freqLbl = freq >= 1000
            ? String(format: "%.1f kHz", freq / 1000)
            : String(format: "%.0f Hz", freq)
        let sign    = delta >= 0 ? "+" : ""

        Text("\(freqLbl)  Δ\(sign)\(String(format: "%.1f", delta)) dB")
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.72))
            .cornerRadius(3)
            .padding(.top, 2)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
    }

    // MARK: - Meters Zone

    private var metersZone: some View {
        HStack(spacing: 12) {
            HStack(spacing: 16) {
                HorizontalMasterMeterRow(
                    label: "IN",
                    peakFraction: meterBridge.inputPeakFraction,
                    rmsFraction:  meterBridge.inputRmsFraction,
                    isClipping:   meterBridge.inputIsClipping
                )
                .frame(minWidth: 140)

                HorizontalMasterMeterRow(
                    label: "OUT",
                    peakFraction: meterBridge.outputPeakFraction,
                    rmsFraction:  meterBridge.outputRmsFraction,
                    isClipping:   meterBridge.outputIsClipping
                )
                .frame(minWidth: 140)
            }
            .padding(.horizontal, 8)

            Spacer()

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

    // MARK: - Diagnostics Panel

    private var diagnosticsPanel: some View {
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

    // MARK: - Clip helpers

    private var clipGlowing: Bool   { meterBridge.inputIsClipping || meterBridge.outputIsClipping }
    private var clipColour:  Color  { clipGlowing ? .red : Color.secondary.opacity(0.4) }
    private var clipGlowColour: Color { clipGlowing ? .red.opacity(0.8) : .clear }
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
