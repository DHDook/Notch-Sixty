import Atomics
import AudioToolbox
import CoreAudio
import Foundation

/// Real-time dynamics processor implementing a soft clipper followed by a brickwall limiter.
///
/// Signal chain (per buffer):
/// ```
/// Input → [Soft Clipper] → [Look-Ahead Ring Buffer] → [Brickwall Limiter] → Output
/// ```
///
/// Thread safety: atomic parameters are written by the main thread and read by the audio
/// thread. All ring-buffer and envelope state is accessed exclusively from the audio thread
/// and is marked `nonisolated(unsafe)`.
final class DynamicsProcessor: @unchecked Sendable {

    // MARK: - Constants

    /// Safe ring-buffer ceiling: 384 kHz × 0.002 s = 768 samples; round up to a power-of-two-adjacent safe value.
    static let maxLookAheadSamples: Int = 2048

    // MARK: - Audio-Thread State

    private let channelCount: Int

    /// Pre-allocated look-ahead ring buffers, one per channel.
    private let lookAheadBufs: [UnsafeMutablePointer<Float>]

    /// Current number of look-ahead samples (function of sample rate, capped to maxLookAheadSamples).
    nonisolated(unsafe) var lookAheadSize: Int

    /// Ring-buffer write position (audio thread only).
    nonisolated(unsafe) var lookAheadWriteIndex: Int = 0

    /// Smoothed limiter gain coefficient g_c (audio thread only).
    nonisolated(unsafe) var limiterGainCurrent: Float = 1.0

    // MARK: - Atomic Parameters (main thread → audio thread)

    private let _softClipperEnabled: ManagedAtomic<Int32>
    private let _softClipperDrive: ManagedAtomic<Int32>       // linear amplitude, as Float bits
    private let _softClipperThreshold: ManagedAtomic<Int32>   // linear amplitude, as Float bits
    private let _softClipperKnee: ManagedAtomic<Int32>        // 0.001–1.0, as Float bits

    private let _limiterEnabled: ManagedAtomic<Int32>
    private let _limiterCeiling: ManagedAtomic<Int32>         // linear amplitude, as Float bits
    private let _limiterAlphaRelease: ManagedAtomic<Int32>    // exp(-1/(tau*sr)), as Float bits

    // MARK: - Gain Reduction Reporting (audio thread → main thread)

    private let _gainReductionBits: ManagedAtomic<Int32>      // Float bits of dB value

    /// Latest gain reduction in dB (0.0 = no reduction, negative = gain applied).
    /// Safe to read from any thread.
    var gainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _gainReductionBits.load(ordering: .relaxed)))
    }

    // MARK: - Initialization

    init(channelCount: UInt32, sampleRate: Double) {
        self.channelCount = Int(channelCount)

        // Allocate look-ahead ring buffers
        var bufs: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<Int(channelCount) {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLookAheadSamples)
            p.initialize(repeating: 0, count: Self.maxLookAheadSamples)
            bufs.append(p)
        }
        self.lookAheadBufs = bufs
        self.lookAheadSize = Self.computeLookAheadSamples(sampleRate: sampleRate)

        // Default parameter values
        let defaultDrive      = Self.dbToLinear(0.0)
        let defaultThreshold  = Self.dbToLinear(-1.5)
        let defaultKnee       = Float(0.5)
        let defaultCeiling    = Self.dbToLinear(-0.2)
        let defaultReleaseTau = Float(0.020)    // 20 ms in seconds
        let defaultAlpha      = Self.computeAlpha(tauSeconds: defaultReleaseTau, sampleRate: sampleRate)

        _softClipperEnabled  = ManagedAtomic(0)
        _softClipperDrive    = ManagedAtomic(floatBits(defaultDrive))
        _softClipperThreshold = ManagedAtomic(floatBits(defaultThreshold))
        _softClipperKnee     = ManagedAtomic(floatBits(defaultKnee))

        _limiterEnabled      = ManagedAtomic(1)
        _limiterCeiling      = ManagedAtomic(floatBits(defaultCeiling))
        _limiterAlphaRelease = ManagedAtomic(floatBits(defaultAlpha))

        _gainReductionBits   = ManagedAtomic(floatBits(0.0))
    }

    deinit {
        for p in lookAheadBufs {
            p.deinitialize(count: Self.maxLookAheadSamples)
            p.deallocate()
        }
    }

    // MARK: - Parameter Update API (main thread)

    func setSoftClipperEnabled(_ enabled: Bool) {
        _softClipperEnabled.store(enabled ? 1 : 0, ordering: .relaxed)
    }

    func setSoftClipperDriveDB(_ db: Float) {
        _softClipperDrive.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }

    func setSoftClipperThresholdDB(_ db: Float) {
        _softClipperThreshold.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }

    func setSoftClipperKnee(_ knee: Float) {
        let clamped = max(0.001, min(1.0, knee))
        _softClipperKnee.store(floatBits(clamped), ordering: .relaxed)
    }

    func setLimiterEnabled(_ enabled: Bool) {
        _limiterEnabled.store(enabled ? 1 : 0, ordering: .relaxed)
    }

    func setLimiterCeilingDB(_ db: Float) {
        _limiterCeiling.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }

    func setLimiterReleaseMs(_ ms: Float, sampleRate: Double) {
        let tau = ms / 1000.0
        let alpha = Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)
        _limiterAlphaRelease.store(floatBits(alpha), ordering: .relaxed)
    }

    /// Applies the full config snapshot atomically (main thread).
    func applyConfig(_ config: DynamicsConfig, sampleRate: Double) {
        setSoftClipperEnabled(config.softClipper.isEnabled)
        setSoftClipperDriveDB(config.softClipper.driveDB)
        setSoftClipperThresholdDB(config.softClipper.thresholdDB)
        setSoftClipperKnee(config.softClipper.kneeSmooth)
        setLimiterEnabled(config.limiter.isEnabled)
        setLimiterCeilingDB(config.limiter.ceilingDB)
        setLimiterReleaseMs(config.limiter.releaseMs, sampleRate: sampleRate)
    }

    /// Called when the pipeline sample rate changes.
    /// Zeros look-ahead buffers to prevent memory-corruption artefacts, resets envelope state,
    /// and recomputes sample-rate-dependent time constants.
    func updateSampleRate(_ sampleRate: Double, releaseMs: Float) {
        // Zero out look-ahead buffers before any new audio arrives
        for p in lookAheadBufs {
            p.initialize(repeating: 0, count: Self.maxLookAheadSamples)
        }
        lookAheadWriteIndex = 0
        lookAheadSize = Self.computeLookAheadSamples(sampleRate: sampleRate)
        limiterGainCurrent = 1.0

        // Recompute alpha from the stored release time
        let tau = releaseMs / 1000.0
        let alpha = Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)
        _limiterAlphaRelease.store(floatBits(alpha), ordering: .relaxed)
    }

    // MARK: - DSP Processing (audio thread)

    /// Processes audio in-place through the soft clipper and brickwall limiter.
    /// Must be called exclusively from the audio render thread.
    ///
    /// - Parameters:
    ///   - bufferList: Output AudioBufferList to process in-place (deinterleaved float32).
    ///   - frameCount: Number of frames to process.
    @inline(__always)
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let count = Int(frameCount)
        guard count > 0 else { return }

        let abl = UnsafeMutableAudioBufferListPointer(bufferList)

        // Build mutable channel pointer array without heap allocation when possible
        let numCh = min(channelCount, abl.count)
        guard numCh > 0 else { return }

        // Load all parameters once per buffer for consistency (single atomic read each)
        let softEnabled  = _softClipperEnabled.load(ordering: .relaxed) != 0
        let limEnabled   = _limiterEnabled.load(ordering: .relaxed) != 0

        guard softEnabled || limEnabled else {
            _gainReductionBits.store(floatBits(0.0), ordering: .relaxed)
            return
        }

        let driveLinear  = bitsToFloat(_softClipperDrive.load(ordering: .relaxed))
        let threshold    = bitsToFloat(_softClipperThreshold.load(ordering: .relaxed))
        let knee         = bitsToFloat(_softClipperKnee.load(ordering: .relaxed))
        let ceiling      = bitsToFloat(_limiterCeiling.load(ordering: .relaxed))
        let alphaRelease = bitsToFloat(_limiterAlphaRelease.load(ordering: .relaxed))

        // Pre-compute soft-clipper knee region boundaries
        let halfKnee     = knee * 0.5
        let xLower       = threshold - halfKnee
        let xUpper       = threshold + halfKnee
        let invTwoKnee   = (knee > 1e-9) ? (1.0 / (2.0 * knee)) : 0.0

        let la           = max(1, min(lookAheadSize, Self.maxLookAheadSamples))
        var writeIdx     = lookAheadWriteIndex
        var gC           = limiterGainCurrent
        var lastGC       = gC

        for frame in 0..<count {
            // ── Soft Clipper ────────────────────────────────────────────────────
            if softEnabled {
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    buf[frame] = softClip(
                        buf[frame] * driveLinear,
                        threshold: threshold,
                        xLower: xLower,
                        xUpper: xUpper,
                        invTwoKnee: invTwoKnee
                    )
                }
            }

            // ── Brickwall Limiter ────────────────────────────────────────────────
            if limEnabled {
                // 1. Write current (possibly soft-clipped) sample into look-ahead buffers
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    lookAheadBufs[ch][writeIdx] = buf[frame]
                }

                // 2. Detect inter-channel peak across the entire look-ahead window
                var peakAmplitude: Float = 0.0
                for ch in 0..<numCh {
                    let chPeak = scanPeak(lookAheadBufs[ch], size: la)
                    if chPeak > peakAmplitude { peakAmplitude = chPeak }
                }

                // 3. Compute target gain
                let gTarget: Float
                if peakAmplitude > ceiling && peakAmplitude > 1e-9 {
                    gTarget = ceiling / peakAmplitude
                } else {
                    gTarget = 1.0
                }

                // 4. Envelope smoothing — instant attack, smooth release
                if gTarget < gC {
                    gC = gTarget                            // instant attack
                } else {
                    gC = gC * alphaRelease + gTarget * (1.0 - alphaRelease)  // smooth release
                }

                // 5. Read the delayed sample (L frames old) and apply smoothed gain
                let readIdx = (writeIdx + 1) % la
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    buf[frame] = lookAheadBufs[ch][readIdx] * gC
                }

                lastGC  = gC
                writeIdx = (writeIdx + 1) % la
            }
        }

        lookAheadWriteIndex = writeIdx
        limiterGainCurrent  = gC

        // ── Gain Reduction Tracking ──────────────────────────────────────────────
        // Gain_Reduction_dB = 20 * log10(g_c)  [stored atomically for UI read]
        let grDB = (lastGC > 1e-9) ? (20.0 * log10(lastGC)) : Float(-90.0)
        _gainReductionBits.store(floatBits(grDB), ordering: .relaxed)
    }

    // MARK: - Inner DSP Math

    /// Soft-clipper wave-shaper with quadratic soft knee.
    ///
    /// For |x| ≤ x_lower                    → f(x) = x                  (linear)
    /// For |x| > x_upper                    → f(x) = sign(x) * threshold (hard clip)
    /// For x_lower < |x| ≤ x_upper (knee)   → quadratic blend
    ///   f(x) = sign(x) * (x_lower + delta - delta² / (2k))
    ///   where delta = |x| − x_lower
    @inline(__always)
    private func softClip(
        _ x: Float,
        threshold: Float,
        xLower: Float,
        xUpper: Float,
        invTwoKnee: Float
    ) -> Float {
        let absX: Float = x < 0 ? -x : x
        let sign: Float = x >= 0 ? 1.0 : -1.0

        if absX <= xLower {
            return x
        } else if absX > xUpper {
            return sign * threshold
        } else {
            let delta = absX - xLower
            return sign * (xLower + delta - delta * delta * invTwoKnee)
        }
    }

    /// Scans `buffer[0..<size]` for the absolute maximum value.
    @inline(__always)
    private func scanPeak(_ buffer: UnsafeMutablePointer<Float>, size: Int) -> Float {
        var peak: Float = 0.0
        for i in 0..<size {
            let v = buffer[i]
            let absV = v < 0 ? -v : v
            if absV > peak { peak = absV }
        }
        return peak
    }

    // MARK: - Static Helpers

    /// Converts dB to linear amplitude: x_linear = 10^(dB / 20).
    static func dbToLinear(_ db: Float) -> Float {
        pow(10.0, db / 20.0)
    }

    /// Number of look-ahead samples for the fixed 2 ms window at a given sample rate.
    static func computeLookAheadSamples(sampleRate: Double) -> Int {
        let samples = Int((sampleRate * BrickwallLimiterConfig.lookAheadMs / 1000.0).rounded(.up))
        return min(max(1, samples), maxLookAheadSamples)
    }

    /// Release-time alpha coefficient: alpha = exp(−1 / (tau × sampleRate)).
    static func computeAlpha(tauSeconds: Float, sampleRate: Double) -> Float {
        Float(exp(-1.0 / (Double(tauSeconds) * sampleRate)))
    }
}

// MARK: - Bit-casting helpers (inline, no boxing)

@inline(__always)
private func floatBits(_ f: Float) -> Int32 {
    Int32(bitPattern: f.bitPattern)
}

@inline(__always)
private func bitsToFloat(_ bits: Int32) -> Float {
    Float(bitPattern: UInt32(bitPattern: bits))
}
