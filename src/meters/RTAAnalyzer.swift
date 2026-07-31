// RTAAnalyzer.swift
// Dual 31-band real-time spectrum analyser — pre-EQ (input) and post-dynamics (output).

import Accelerate
import AppKit
import Combine
import Foundation

// MARK: - Data Types

/// Represents the current display state for one RTA frequency band.
struct BandData {
    var currentValue: Float = -60.0
    var peakValue:    Float = -60.0
    var peakHoldFrames: Int = 0
}

/// Biquad coefficient set for theoretical frequency-response overlay.
/// Uses standard IIR form (NOT the pre-negated na1/na2 convention of BiquadCoefficients).
struct BiquadCoefficientsRTA {
    let b0: Double, b1: Double, b2: Double
    let a1: Double, a2: Double
}

// MARK: - Lock-Free Ring Buffer

/// Single-producer / single-consumer ring buffer for RTA audio samples.
/// Written from the real-time audio thread; read from the analysis timer on the main thread.
/// Thread safety relies on the SPSC guarantee: only one writer, only one reader.
final class LockFreeAudioRingBuffer: @unchecked Sendable {
    private let bufferSize: Int
    private let buffer:     UnsafeMutablePointer<Float>
    // writeIndex is updated exclusively by the audio thread.
    // readIndex is updated exclusively by the consumer thread.
    // Both are stored as Int (word-size atomic on all Apple platforms).
    nonisolated(unsafe) private var writeIndex: Int = 0
    nonisolated(unsafe) private var readIndex:  Int = 0

    init(bufferSize: Int = 8192) {
        self.bufferSize = bufferSize
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Audio Thread API

    /// Writes interleaved stereo samples as mono (L+R)/2 to the ring buffer.
    /// Must only be called from the audio render thread.
    @inline(__always)
    func writeStereoSamples(
        leftChannel:  UnsafePointer<Float>,
        rightChannel: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let wi = writeIndex
        for i in 0..<frameCount {
            buffer[(wi + i) & (bufferSize - 1)] = (leftChannel[i] + rightChannel[i]) * 0.5
        }
        // Store-release ensures the audio thread's writes are visible before we advance the index.
        writeIndex = (wi + frameCount) & (bufferSize - 1)
    }

    // MARK: - Consumer Thread API

    /// Returns the most recent `size` mono samples from the write head.
    /// Must only be called from the consumer thread (main actor or analysis queue).
    func readLatestChunk(size: Int = 2048) -> [Float] {
        let n = min(size, bufferSize)
        var chunk = [Float](repeating: 0, count: n)
        let wi = writeIndex  // load-acquire
        var start = wi - n
        if start < 0 { start += bufferSize }
        for i in 0..<n {
            chunk[i] = buffer[(start + i) & (bufferSize - 1)]
        }
        return chunk
    }

    /// Reads the most recent `dest.count` samples into a pre-allocated buffer.
    /// Avoids heap allocation on the hot path.
    func readLatestChunkInto(_ dest: inout [Float]) {
        let n = min(dest.count, bufferSize)
        let wi = writeIndex
        var start = wi - n
        if start < 0 { start += bufferSize }
        for i in 0..<n {
            dest[i] = buffer[(start + i) & (bufferSize - 1)]
        }
    }
}

// MARK: - Analyser

/// Dual 31-band real-time spectrum analyser (ISO 1/3-octave centre frequencies).
/// The two ring buffers must be filled from the audio render thread via
/// `RenderCallbackContext.writeRTAInput/Output(…)`.
/// An internal 20 Hz timer drives FFT analysis and publishes results on the main actor.
@MainActor
final class AdvancedDualSpectrumAnalyzer: ObservableObject, @unchecked Sendable {

    // MARK: Tunable limits
    let minDb: Float = -80.0
    let maxDb: Float =   0.0   // 0 dBFS = full bar height

    // MARK: Ring buffers — written by the audio thread
    let inputRingBuffer  = LockFreeAudioRingBuffer(bufferSize: 524_288)
    let outputRingBuffer = LockFreeAudioRingBuffer(bufferSize: 524_288)

    // MARK: Multi-resolution FFT lane state

    private final class FFTLane {
        let fftSize: Int
        let log2n: vDSP_Length
        var window: [Float]
        var tickInputSamples: [Float]
        var tickOutputSamples: [Float]
        var scratchWindowed: [Float]
        var scratchReal: [Float]
        var scratchImag: [Float]
        var scratchMags: [Float]
        var scratchAmps: [Float]
        var scratchResultDb: [Float]
        var lastInputDb: [Float]?
        var lastOutputDb: [Float]?
        var tickSkipCounter: Int = 0

        init(fftSize: Int) {
            self.fftSize = fftSize
            self.log2n = vDSP_Length(log2(Float(fftSize)))
            let half = fftSize / 2
            window = [Float](repeating: 0, count: fftSize)
            tickInputSamples = [Float](repeating: 0, count: fftSize)
            tickOutputSamples = [Float](repeating: 0, count: fftSize)
            scratchWindowed = [Float](repeating: 0, count: fftSize)
            scratchReal = [Float](repeating: 0, count: half)
            scratchImag = [Float](repeating: 0, count: half)
            scratchMags = [Float](repeating: 0, count: half)
            scratchAmps = [Float](repeating: 0, count: half)
            scratchResultDb = [Float](repeating: 0, count: half)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }
    }

    private var lanes: [FFTLane] = []

    // One shared FFTSetup, created once at the maximum size needed (log2n = 18 for 262144)
    nonisolated(unsafe) private var fftSetup: FFTSetup

    // MARK: Analysis rate
    private let analysisRateHz: Double = 30.0
    private var tickInterval: TimeInterval { 1.0 / analysisRateHz }

    // MARK: Ballistics (time constants are real-world seconds; per-tick alphas are derived below)
    private let fallingTimeConstant: Double = 0.1     // ~existing falling feel, ~98ms measured from old 0.60 @20Hz
    private let peakDecayTimeConstant: Double = 0.4    // ~existing post-hold decay feel, ~391ms measured from old 0.88 @20Hz
    private let peakHoldSeconds: Double = 1.0          // was 1.5s @20Hz; product decision: speed up to 1.0s @60Hz

    private let risingAlpha:  Float = 1.00  // instant attack
    internal lazy var fallingAlpha: Float  = Float(exp(-tickInterval / fallingTimeConstant))
    internal lazy var peakDecay: Float     = Float(exp(-tickInterval / peakDecayTimeConstant))
    internal lazy var peakHoldMax: Int     = Int((peakHoldSeconds * analysisRateHz).rounded())

    // MARK: Display Mode
    enum RTADisplayMode: Sendable {
        case standard
        case slowAverage(seconds: Double)
    }

    @Published var displayMode: RTADisplayMode = .standard

    // MARK: Slow averaging state
    private var slowAverageBands: [Float] = Array(repeating: -60.0, count: 31)
    private var slowAverageAlpha: Float = 0.0  // Computed from time constant

    // MARK: Published outputs
    let centerFrequencies: [Float] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250,
        1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
        10000, 12500, 16000, 20000
    ]

    @Published var inputBands:       [BandData] = Array(repeating: BandData(), count: 31)
    @Published var outputBands:      [BandData] = Array(repeating: BandData(), count: 31)
    @Published var targetLinePoints: [Float]    = []
    @Published var showInputPeaks:   Bool = true
    @Published var showOutputPeaks:  Bool = true
    @Published var showDiagnostics:  Bool = false
    @Published var currentFps:       Int  = 0

    // Assumed sample rate when no pipeline info is available.
    var assumedSampleRate: Float = 48000 {
        didSet {
            rebuildLanes(for: assumedSampleRate)
        }
    }

    // MARK: Multi-resolution FFT lane configuration

    /// Reference lane sizes at 48kHz. Each is the smallest power of two whose window
    /// (size/sampleRate) satisfies window >= 2 / (bandwidth of the narrowest band in that lane),
    /// the standard Hann-window frequency-resolution rule of thumb.
    private static let laneReferenceSizes: [Int] = [32768, 8192, 2048, 512, 128]
    private static let laneReferenceSampleRate: Float = 48000

    /// Fixed assignment of each of the 31 ISO 1/3-octave bands (in `centerFrequencies` order) to a
    /// lane index. This assignment does NOT depend on sample rate — only each lane's *size* does.
    ///   Lane 0: 20, 25, 31.5, 40, 50 Hz          (window ≈ 683ms @48kHz)
    ///   Lane 1: 63, 80, 100, 125, 160, 200 Hz    (window ≈ 171ms @48kHz)
    ///   Lane 2: 250, 315, 400, 500, 630, 800 Hz  (window ≈ 43ms  @48kHz)
    ///   Lane 3: 1000–3150 Hz (6 bands)           (window ≈ 11ms  @48kHz)
    ///   Lane 4: 4000–20000 Hz (8 bands)          (window ≈ 2.7ms @48kHz)
    private static let bandLaneIndex: [Int] = [
        0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1,
        2, 2, 2, 2, 2, 2,
        3, 3, 3, 3, 3, 3,
        4, 4, 4, 4, 4, 4, 4, 4,
    ]

    /// How many ticks to wait between recomputing each lane, to skip redundant work on lanes whose
    /// content physically cannot change faster than their own window duration. Lane 0's window is
    /// ~680ms, so recomputing it every tick (e.g. every 33ms @30Hz) is wasted work; every 4th tick
    /// (still ~130ms @30Hz, well under its 680ms window) loses nothing perceptible. Lanes 1–4 are
    /// cheap enough, and change fast enough, to recompute every tick.
    private static let laneUpdateDivisor: [Int] = [4, 1, 1, 1, 1]

    /// Computes each lane's actual FFT size for a given sample rate, preserving each lane's
    /// reference window duration (and therefore its frequency resolution) at every sample rate.
    private func laneSizes(for sampleRate: Float) -> [Int] {
        Self.laneReferenceSizes.map { refSize in
            let scaled = Double(refSize) * Double(sampleRate) / Double(Self.laneReferenceSampleRate)
            return nextPowerOfTwo(Int(scaled.rounded(.up)))
        }
    }

    private func nextPowerOfTwo(_ x: Int) -> Int {
        guard x > 1 else { return 1 }
        return 1 << (Int.bitWidth - (x - 1).leadingZeroBitCount)
    }

    // MARK: Band route cache for multi-lane band routing
    private struct BandRoute {
        let laneIndex: Int
        let loBinIndex: Int
        let hiBinIndex: Int
        let fallbackBinIndex: Int
    }
    private var bandRouteCache: [Float: [BandRoute]] = [:]

    // MARK: FPS tracking
    private var frameCount: Int  = 0
    private var lastFpsTick: Date = Date()

    // MARK: Timer
    private var updateTimer: AnyCancellable?

    // MARK: Run state gating
    private var isWindowVisible = true
    private var isMetersEnabled = true
    private var isIndividuallyEnabled = true
    private weak var equaliserWindow: NSWindow?

    // MARK: - Init / deinit

    init() {
        // Create shared FFTSetup at max size needed (log2n = 18 for 262144 at 384kHz)
        let maxLog2n = vDSP_Length(18)
        self.fftSetup = vDSP_create_fftsetup(maxLog2n, FFTRadix(kFFTRadix2))!

        // Build initial lanes from current assumed sample rate
        rebuildLanes(for: assumedSampleRate)

        updateRunState()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Lane rebuilding on sample-rate change

    private func rebuildLanes(for sampleRate: Float) {
        let sizes = laneSizes(for: sampleRate)
        let newLanes = sizes.map { FFTLane(fftSize: $0) }

        // Skip rebuild if sizes are unchanged (avoids redundant work when assumedSampleRate
        // is set to the same value it already was)
        if lanes.count == newLanes.count,
           zip(lanes, newLanes).allSatisfy({ $0.fftSize == $1.fftSize }) {
            return
        }

        lanes = newLanes
    }

    // MARK: - Timer

    private func updateRunState() {
        if isWindowVisible && isMetersEnabled && isIndividuallyEnabled {
            guard updateTimer == nil else { return }
            startTimer()
        } else {
            updateTimer?.cancel()
            updateTimer = nil
        }
    }

    private func startTimer() {
        updateTimer = Timer.publish(every: tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    // MARK: - Public API for run state control

    func setMetersEnabled(_ enabled: Bool) {
        isMetersEnabled = enabled
        updateRunState()
    }

    func setIndividuallyEnabled(_ enabled: Bool) {
        isIndividuallyEnabled = enabled
        updateRunState()
    }

    /// Mirrors MeterStore.setEqualiserWindow's NSWindow visibility observation —
    /// see MeterStore.swift for the exact notification pattern being replicated here.
    func setEqualiserWindow(_ window: NSWindow?) {
        if let oldWindow = equaliserWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: oldWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: oldWindow)
        }
        equaliserWindow = window
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidMiniaturize),
                name: NSWindow.didMiniaturizeNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidDeminiaturize),
                name: NSWindow.didDeminiaturizeNotification,
                object: window
            )
            isWindowVisible = window.isVisible
        } else {
            isWindowVisible = true  // no window reference yet — don't block on it
        }
        updateRunState()
    }

    @objc private func windowDidMiniaturize() {
        isWindowVisible = false
        updateRunState()
    }

    @objc private func windowDidDeminiaturize() {
        isWindowVisible = true
        updateRunState()
    }

    private func tick() {
        let sr = assumedSampleRate
        var laneInputDb:  [[Float]] = []
        var laneOutputDb: [[Float]] = []

        for laneIdx in lanes.indices {
            let lane = lanes[laneIdx]
            lane.tickSkipCounter += 1
            let divisor = Self.laneUpdateDivisor[laneIdx]

            if lane.tickSkipCounter >= divisor || lane.lastInputDb == nil {
                inputRingBuffer.readLatestChunkInto(&lane.tickInputSamples)
                outputRingBuffer.readLatestChunkInto(&lane.tickOutputSamples)
                lane.lastInputDb  = executeLaneFFT(lane, samples: lane.tickInputSamples)
                lane.lastOutputDb = executeLaneFFT(lane, samples: lane.tickOutputSamples)
                lane.tickSkipCounter = 0
            }
            laneInputDb.append(lane.lastInputDb!)
            laneOutputDb.append(lane.lastOutputDb!)
        }

        let tgtIn  = mapBandsFromLanes(laneMagnitudes: laneInputDb,  sampleRate: sr)
        let tgtOut = mapBandsFromLanes(laneMagnitudes: laneOutputDb, sampleRate: sr)
        applyBallistics(bands: &inputBands,  targets: tgtIn)
        applyBallistics(bands: &outputBands, targets: tgtOut)

        // FPS counter
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFpsTick)
        if elapsed >= 1.0 {
            currentFps  = Int(Double(frameCount) / elapsed)
            frameCount  = 0
            lastFpsTick = now
        }
    }

    // MARK: - Public API

    /// Maps a raw dB value to a 0–1 normalised position for display.
    func normaliseDb(_ db: Float) -> Float {
        (max(minDb, min(maxDb, db)) - minDb) / (maxDb - minDb)
    }

    /// Static version — safe to call from Canvas closures without capturing `self`.
    static func normaliseDbStatic(_ db: Float, min minDb: Float, max maxDb: Float) -> Float {
        (Swift.max(minDb, Swift.min(maxDb, db)) - minDb) / (maxDb - minDb)
    }

    /// Computes theoretical frequency-response overlay from a set of biquad filters.
    func updateTargetLine(
        activeFilters: [BiquadCoefficientsRTA],
        outputGainDb:  Float,
        sampleRate:    Double
    ) {
        let points: [Float] = centerFrequencies.map { fc in
            var gainDb = Double(outputGainDb)
            let w  = 2.0 * Double.pi * Double(fc) / sampleRate
            let cw = cos(w), s2w = sin(2.0 * w), c2w = cos(2.0 * w), sw = sin(w)
            for f in activeFilters {
                let nr  =  f.b0 + f.b1 * cw + f.b2 * c2w
                let ni  = -(f.b1 * sw + f.b2 * s2w)
                let dr  =  1.0  + f.a1 * cw + f.a2 * c2w
                let di  = -(f.a1 * sw + f.a2 * s2w)
                let numMag2 = nr * nr + ni * ni
                let denMag2 = dr * dr + di * di
                if denMag2 > 0 { gainDb += 10.0 * log10(numMag2 / denMag2) }
            }
            return normaliseDb(Float(gainDb))
        }
        targetLinePoints = points
    }

    /// Updates both band arrays from raw sample arrays.
    /// Called internally from the timer; may also be driven externally for testing.
    func updateSmearedSpectrums(
        inputSamples:  [Float], inputGainDb:  Float,
        outputSamples: [Float], outputGainDb: Float,
        sampleRate: Float
    ) {
        // Ensure lanes are built for this sample rate
        if assumedSampleRate != sampleRate {
            assumedSampleRate = sampleRate
        }

        // Execute FFT on all lanes for input and output
        var laneInputDb:  [[Float]] = []
        var laneOutputDb: [[Float]] = []

        for lane in lanes {
            var rawIn  = executeLaneFFT(lane, samples: inputSamples)
            var rawOut = executeLaneFFT(lane, samples: outputSamples)

            if inputGainDb != 0 {
                var g = inputGainDb
                var result = [Float](repeating: 0, count: rawIn.count)
                rawIn.withUnsafeBufferPointer { src in
                    result.withUnsafeMutableBufferPointer { dst in
                        vDSP_vsadd(src.baseAddress!, 1, &g, dst.baseAddress!, 1, vDSP_Length(rawIn.count))
                    }
                }
                rawIn = result
            }
            if outputGainDb != 0 {
                var g = outputGainDb
                var result = [Float](repeating: 0, count: rawOut.count)
                rawOut.withUnsafeBufferPointer { src in
                    result.withUnsafeMutableBufferPointer { dst in
                        vDSP_vsadd(src.baseAddress!, 1, &g, dst.baseAddress!, 1, vDSP_Length(rawOut.count))
                    }
                }
                rawOut = result
            }

            laneInputDb.append(rawIn)
            laneOutputDb.append(rawOut)
        }

        let tgtIn  = mapBandsFromLanes(laneMagnitudes: laneInputDb,  sampleRate: sampleRate)
        let tgtOut = mapBandsFromLanes(laneMagnitudes: laneOutputDb, sampleRate: sampleRate)

        applyBallistics(bands: &inputBands,  targets: tgtIn)
        applyBallistics(bands: &outputBands, targets: tgtOut)
    }

    // MARK: - Private DSP

    private func executeLaneFFT(_ lane: FFTLane, samples: [Float]) -> [Float] {
        let half = lane.fftSize / 2
        guard samples.count >= lane.fftSize else { return [Float](repeating: minDb, count: half) }

        vDSP_vmul(samples, 1, lane.window, 1, &lane.scratchWindowed, 1, vDSP_Length(lane.fftSize))

        lane.scratchWindowed.withUnsafeBytes { windowBytes in
            lane.scratchReal.withUnsafeMutableBytes { realBytes in
                lane.scratchImag.withUnsafeMutableBytes { imagBytes in
                    let complexPtr = windowBytes.bindMemory(to: DSPComplex.self)
                    let realPtr = realBytes.bindMemory(to: Float.self).baseAddress!
                    let imagPtr = imagBytes.bindMemory(to: Float.self).baseAddress!
                    var split = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
            }
        }

        lane.scratchReal.withUnsafeMutableBytes { realBytes in
            lane.scratchImag.withUnsafeMutableBytes { imagBytes in
                let realPtr = realBytes.bindMemory(to: Float.self).baseAddress!
                let imagPtr = imagBytes.bindMemory(to: Float.self).baseAddress!
                var split = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
                // Shared fftSetup, but THIS lane's log2n — this is what makes one setup work for all lanes.
                vDSP_fft_zrip(fftSetup, &split, 1, lane.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &lane.scratchMags, 1, vDSP_Length(half))
            }
        }

        var n = Int32(half)
        vvsqrtf(&lane.scratchAmps, &lane.scratchMags, &n)

        var norm: Float = 4.0 / Float(lane.fftSize)
        vDSP_vsmul(lane.scratchAmps, 1, &norm, &lane.scratchAmps, 1, vDSP_Length(half))

        var ref: Float = 1.0
        vDSP_vdbcon(lane.scratchAmps, 1, &ref, &lane.scratchResultDb, 1, vDSP_Length(half), 1)

        var clipped = lane.scratchResultDb
        var floorVal = minDb
        var ceilVal  = maxDb
        vDSP_vclip(&clipped, 1, &floorVal, &ceilVal, &lane.scratchResultDb, 1, vDSP_Length(half))

        return lane.scratchResultDb
    }

    private func mapBandsFromLanes(laneMagnitudes: [[Float]], sampleRate: Float) -> [Float] {
        var out = [Float](repeating: minDb, count: 31)

        let sizes = laneSizes(for: sampleRate)
        let routes: [BandRoute]
        if let cached = bandRouteCache[sampleRate] {
            routes = cached
        } else {
            routes = computeBandRoutes(sampleRate: sampleRate, laneSizes: sizes)
            bandRouteCache[sampleRate] = routes
        }

        for k in 0..<31 {
            let route = routes[k]
            let dbMagnitudes = laneMagnitudes[route.laneIndex]

            // Guard required (same reason as the single-FFT version): a band can be narrower than
            // one bin even within its own dedicated lane, at the high end of that lane's supported
            // sample-rate range. Constructing loBinIndex...hiBinIndex directly when empty traps.
            if route.loBinIndex <= route.hiBinIndex {
                for i in route.loBinIndex...route.hiBinIndex {
                    if dbMagnitudes[i] > out[k] {
                        out[k] = dbMagnitudes[i]
                    }
                }
            }
            if out[k] == minDb {
                out[k] = dbMagnitudes[route.fallbackBinIndex]
            }
        }
        return out
    }

    private func computeBandRoutes(sampleRate: Float, laneSizes: [Int]) -> [BandRoute] {
        var routes: [BandRoute] = []
        for k in 0..<31 {
            let laneIndex = Self.bandLaneIndex[k]
            let laneFftSize = laneSizes[laneIndex]
            let binWidth = sampleRate / Float(laneFftSize)
            let half = laneFftSize / 2
            let fc = centerFrequencies[k]
            let lo = fc * pow(2.0, -1.0 / 6.0)
            let hi = fc * pow(2.0,  1.0 / 6.0)
            let loBinIndex = max(0, Int(ceil(lo / binWidth)))
            let hiBinIndex = min(half - 1, Int(floor(hi / binWidth)))
            let fallbackBinIndex = max(0, min(Int(round(fc / binWidth)), half - 1))
            routes.append(BandRoute(laneIndex: laneIndex, loBinIndex: loBinIndex,
                                     hiBinIndex: hiBinIndex, fallbackBinIndex: fallbackBinIndex))
        }
        return routes
    }

    private func applyBallistics(bands: inout [BandData], targets: [Float]) {
        for i in 0..<min(bands.count, targets.count) {
            let target = targets[i]
            // Attack/decay
            if target > bands[i].currentValue {
                bands[i].currentValue = target
            } else {
                bands[i].currentValue = max(target,
                    bands[i].currentValue * fallingAlpha + target * (1 - fallingAlpha))
            }
            // Peak hold
            if target >= bands[i].peakValue {
                bands[i].peakValue      = target
                bands[i].peakHoldFrames = peakHoldMax
            } else if bands[i].peakHoldFrames > 0 {
                bands[i].peakHoldFrames -= 1
            } else {
                bands[i].peakValue = max(minDb, bands[i].peakValue * peakDecay + minDb * (1 - peakDecay))
            }
        }

        // Apply slow averaging if enabled
        if case .slowAverage(let seconds) = displayMode {
            // Compute alpha from time constant: alpha = 1 - exp(-dt / tau)
            // where dt = tickInterval and tau = seconds
            slowAverageAlpha = 1.0 - Float(exp(-tickInterval / seconds))

            for i in 0..<min(slowAverageBands.count, targets.count) {
                slowAverageBands[i] = slowAverageBands[i] * slowAverageAlpha + targets[i] * (1.0 - slowAverageAlpha)
            }
        }
    }

    /// Returns the current slow-averaged band data as (frequency, gainDB) tuples.
    /// Returns empty array if slow averaging is not enabled.
    func getSlowAverageData() -> [(frequency: Double, gainDB: Double)] {
        guard case .slowAverage = displayMode else { return [] }
        return zip(centerFrequencies, slowAverageBands).map { (Double($0), Double($1)) }
    }
}
