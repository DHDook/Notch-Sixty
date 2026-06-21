// LookAheadLimiter.swift
//
// Look-ahead brickwall limiter with 4-point true-peak (inter-sample peak) detection.
// Extracted from DynamicsProcessor's main-chain limiter so the identical, proven
// algorithm can be reused for per-output-channel limiting (OutputChannelProcessor).
//
// Real-time safe: all buffers pre-allocated in init, no allocation in process().

import Accelerate
import Atomics

final class LookAheadLimiter {

    // MARK: - Configuration (set via atomics from the main thread; read on audio thread)

    private let _ceilingBits       = ManagedAtomic<Int32>(Int32(bitPattern: Float(0.977).bitPattern)) // ≈ -0.2 dBFS
    private let _attackAlphaBits   = ManagedAtomic<Int32>(0)
    private let _releaseAlphaBits  = ManagedAtomic<Int32>(0)
    private let _tpGuardEnabled    = ManagedAtomic<Bool>(false)
    private let _enabled           = ManagedAtomic<Bool>(true)

    // MARK: - Per-channel look-ahead ring buffers (pre-allocated, never resized on audio thread)

    static let maxLookAheadSamples = 8192

    private let lookAheadBufs: [UnsafeMutablePointer<Float>]
    private let channelCount: Int
    private var lookAheadSize: Int
    private var lookAheadWriteIndex: Int = 0
    private var gainCurrent: Float = 1.0

    // MARK: - Metering (read by MeterStore / OutputChannelProcessor)

    /// Most recent gain reduction in dB (≤ 0). Updated every process() call.
    private(set) var lastGainReductionDB: Float = 0.0
    /// True if the true-peak guard tripped (residual inter-sample peak above the
    /// raw, un-derated ceiling) since the last call to clearTruePeakTripped().
    private(set) var truePeakTripped: Bool = false

    // MARK: - Init

    init(channelCount: Int, sampleRate: Double, lookAheadMs: Float = 2.0) {
        self.channelCount = channelCount
        self.lookAheadBufs = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLookAheadSamples)
            p.initialize(repeating: 0, count: Self.maxLookAheadSamples)
            return p
        }
        self.lookAheadSize = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: lookAheadMs)
        setAttackMs(0.1, sampleRate: sampleRate)
        setReleaseMs(20.0, sampleRate: sampleRate)
    }

    deinit {
        for p in lookAheadBufs { p.deinitialize(count: Self.maxLookAheadSamples) }
        for p in lookAheadBufs { p.deallocate() }
    }

    // MARK: - Main Thread Configuration

    func setEnabled(_ enabled: Bool) {
        _enabled.store(enabled, ordering: .releasing)
    }

    func setCeilingDB(_ db: Float) {
        let linear = pow(10.0 as Float, db / 20.0)
        _ceilingBits.store(Int32(bitPattern: linear.bitPattern), ordering: .releasing)
    }

    func setAttackMs(_ ms: Float, sampleRate: Double) {
        let alpha = Self.computeAlpha(timeMs: ms, sampleRate: sampleRate)
        _attackAlphaBits.store(Int32(bitPattern: alpha.bitPattern), ordering: .releasing)
    }

    func setReleaseMs(_ ms: Float, sampleRate: Double) {
        let alpha = Self.computeAlpha(timeMs: ms, sampleRate: sampleRate)
        _releaseAlphaBits.store(Int32(bitPattern: alpha.bitPattern), ordering: .releasing)
    }

    /// Changes the look-ahead buffer size. This resets internal state (acceptable —
    /// look-ahead size changes are rare, user-initiated configuration events, not
    /// per-callback events). Must be called from the main thread; the audio thread
    /// reads lookAheadSize only inside process(), which is never concurrent with this.
    func setLookAheadMs(_ ms: Float, sampleRate: Double) {
        let newSize = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: ms)
        guard newSize != lookAheadSize else { return }
        for p in lookAheadBufs { p.initialize(repeating: 0, count: Self.maxLookAheadSamples) }
        lookAheadWriteIndex = 0
        gainCurrent = 1.0
        lookAheadSize = newSize
    }

    func setTruePeakGuardEnabled(_ enabled: Bool) {
        _tpGuardEnabled.store(enabled, ordering: .releasing)
    }

    func clearTruePeakTripped() {
        truePeakTripped = false
    }

    // MARK: - Audio Thread Processing

    /// Processes `channelCount` buffers in-place, sample-by-sample, applying
    /// look-ahead limiting with optional true-peak guard derating.
    /// `buffers` must have exactly `channelCount` entries, each ≥ `frameCount` long.
    @inline(__always)
    func process(buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard _enabled.load(ordering: .relaxed) else { return }
        precondition(buffers.count == channelCount, "LookAheadLimiter: buffer count mismatch")

        let rawCeiling   = Float(bitPattern: UInt32(bitPattern: _ceilingBits.load(ordering: .relaxed)))
        let tpGuardOn    = _tpGuardEnabled.load(ordering: .relaxed)
        // Same 0.5 dBTP derating as the main-chain implementation, for the same reason:
        // the 4-point FIR interpolator in scanPeak has a theoretical max gain of ≈1.865×;
        // derating the working ceiling gives headroom for estimator uncertainty.
        let ceiling = tpGuardOn ? rawCeiling * 0.9441 : rawCeiling

        let alphaAttack  = Float(bitPattern: UInt32(bitPattern: _attackAlphaBits.load(ordering: .relaxed)))
        let alphaRelease = Float(bitPattern: UInt32(bitPattern: _releaseAlphaBits.load(ordering: .relaxed)))

        let la = max(1, min(lookAheadSize, Self.maxLookAheadSamples))
        var writeIdx = lookAheadWriteIndex
        var gC = gainCurrent
        var lastGC = gC
        var postLimiterPeak: Float = 0.0

        for frame in 0..<frameCount {
            for ch in 0..<channelCount {
                lookAheadBufs[ch][writeIdx] = buffers[ch][frame]
            }
            var peakAmplitude: Float = 0.0
            for ch in 0..<channelCount {
                let p = Self.scanPeak(lookAheadBufs[ch], size: la)
                if p > peakAmplitude { peakAmplitude = p }
            }
            let gTarget: Float = peakAmplitude > ceiling && peakAmplitude > 1e-9
                ? ceiling / peakAmplitude : 1.0
            if gTarget < gC {
                gC = alphaAttack < 1e-6 ? gTarget : gC * alphaAttack + gTarget * (1.0 - alphaAttack)
            } else {
                gC = gC * alphaRelease + gTarget * (1.0 - alphaRelease)
            }
            let readIdx = (writeIdx + 1) % la
            for ch in 0..<channelCount {
                buffers[ch][frame] = lookAheadBufs[ch][readIdx] * gC
            }
            if tpGuardOn {
                for ch in 0..<channelCount {
                    let s = abs(buffers[ch][frame])
                    if s > postLimiterPeak { postLimiterPeak = s }
                }
            }
            lastGC = gC
            writeIdx = (writeIdx + 1) % la
        }

        lookAheadWriteIndex = writeIdx
        gainCurrent = gC
        lastGainReductionDB = lastGC > 1e-9 ? 20.0 * log10(lastGC) : -90.0

        if tpGuardOn && postLimiterPeak > rawCeiling {
            truePeakTripped = true
        }
    }

    // MARK: - Static Helpers (pure, no state)

    /// 4-point FIR true-peak interpolation, identical to the proven main-chain implementation.
    private static func scanPeak(_ buffer: UnsafeMutablePointer<Float>, size: Int) -> Float {
        var peak: Float = 0.0
        for i in 0..<size {
            let s = abs(buffer[i])
            if s > peak { peak = s }
            guard i >= 1, i < size - 2 else { continue }
            let x0 = buffer[i - 1], x1 = buffer[i], x2 = buffer[i + 1], x3 = buffer[i + 2]
            let p1 = abs(-0.1559 * x0 + 0.4989 * x1 + 0.9333 * x2 - 0.2766 * x3)
            let p3 = abs(-0.2766 * x0 + 0.9333 * x1 + 0.4989 * x2 - 0.1559 * x3)
            if p1 > peak { peak = p1 }
            if p3 > peak { peak = p3 }
        }
        return peak
    }

    private static func computeAlpha(timeMs: Float, sampleRate: Double) -> Float {
        guard timeMs > 0 else { return 0.0 }
        let tauSeconds = Double(timeMs) / 1000.0
        return Float(exp(-1.0 / (tauSeconds * sampleRate)))
    }

    private static func computeLookAheadSamples(sampleRate: Double, lookAheadMs: Float) -> Int {
        max(1, min(maxLookAheadSamples, Int(Double(lookAheadMs) / 1000.0 * sampleRate)))
    }
}
