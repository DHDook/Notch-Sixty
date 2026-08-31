// SpectralDenoiser.swift
// Fixes applied:
//   1. Hard binary gate replaced with Wiener soft gain — eliminates musical noise.
//   2. IFFT normalization corrected from 1/N to 1/(2N) — fixes 6 dB level error.
//   3. workImag zeroed with vDSP_vclr instead of Array allocation — real-time safe.
//   4. Configurable noise floor parameter added to Wiener gain.
// Enhancements applied:
//   5. Adaptive per-bin noise floor estimation (minimum statistics).
//   6. Noise profile capture mode.
//   7. Resolution mode selector (Quality / High / Ultra).
//   8. Reduction Amount control with psychoacoustic masking bias.

import Accelerate
import Atomics
import Darwin
import Foundation

enum DenoiserMode: Codable, Equatable {
    case quality   // N=1024, hop=512,  50% overlap
    case high      // N=2048, hop=512,  75% overlap  ← default
    case ultra     // N=4096, hop=1024, 75% overlap

    var fftSize:  Int { switch self { case .quality: 1024; case .high: 2048; case .ultra: 4096 } }
    var hopSize:  Int { switch self { case .quality: 512;  case .high: 512;  case .ultra: 1024 } }
    // Combined IFFT + COLA normalisation scale factor (applied to split-complex arrays of length halfN)
    var normScale: Float {
        switch self {
        case .quality: return 1.0 / Float(fftSize)            // 1/N (50% overlap, COLA=1.0)
        case .high:    return 1.0 / Float(2 * fftSize)        // 1/(2N) (75% overlap, COLA=2.0)
        case .ultra:   return 1.0 / Float(2 * fftSize)        // 1/(2N) (75% overlap, COLA=2.0)
        }
    }
}

final class SpectralDenoiser: @unchecked Sendable {

    // MARK: - Configuration
    private var mode: DenoiserMode
    private var fftSize: Int
    private var hopSize: Int
    private var halfN: Int
    private var sampleRate: Double = 48000.0

    // Gain smoother time constants (instance variables — configurable via setGainSmoothingMs).
    // Defaults match the former hardcoded values (attack ≈ 11 ms, release ≈ 21 ms at 48 kHz/512-hop).
    private var gainAttackMs:    Float = 11.0
    private var gainReleaseMs:   Float = 21.0
    private var gainAttackAlpha:  Float = 0.15
    private var gainReleaseAlpha: Float = 0.30

    // Minimum-statistics history window target duration, in real time. The
    // number of frames retained (historyLength) is computed per-mode from
    // this duration and the active mode's hop size in init()/setMode(), so
    // Quality/High/Ultra all get roughly the same real-time averaging
    // window rather than whatever falls out of hop size incidentally.
    // (Previously a fixed 64 frames meant Quality/High only averaged over
    // ~0.68s while Ultra averaged over ~1.4s — the shorter window let the
    // rolling-minimum noise estimate drift upward faster during sustained
    // loud material, producing audible gain flicker right around transient
    // decay.)
    private static let targetHistoryWindowSeconds: Float = 1.2
    // Number of frames of power history retained. Computed in init() and
    // setMode() from targetHistoryWindowSeconds and the active hop size —
    // do not treat as a compile-time constant elsewhere.
    private var historyLength: Int = 64
    // Bias correction (Martin 2001): the rolling minimum underestimates
    // the true noise power by this factor. 1.66 is standard across the
    // ~50–115 frame range this now produces for the three modes.
    private static let minStatsBias:       Float = 1.66

    // Decision-directed a priori SNR smoothing constant (Ephraim & Malah, 1984).
    // 0.98 is the standard literature value and works well across the hop sizes
    // used by all three DenoiserMode settings; not exposed to the user.
    private static let decisionDirectedAlpha: Float = 0.98

    // Onset/transient detector for adaptive decision-directed alpha. The
    // decision-directed estimator above is known to lag on sudden level
    // increases — its "prior" term is built from the previous (quieter)
    // frame's signal estimate, so for the first frame or two of any
    // transient the gain is briefly under-estimated. This is heard as a
    // short amplitude notch right at the attack (distortion), not smooth
    // musical noise, and gets worse the bigger and more sudden the
    // transient — independent of Reduction Amount, since it's an estimate
    // lag, not a suppression-depth issue. Detecting a broadband energy
    // jump and temporarily using a much faster-responding alpha for that
    // frame fixes it without giving up musical-noise suppression the rest
    // of the time.
    private static let onsetRatioFloorDB: Float = 3.0   // jump below this: no onset adaptation
    private static let onsetRatioCeilDB: Float = 9.0    // jump at/above this: full onset adaptation
    private static let onsetAlpha: Float = 0.3          // ddAlpha used during a full onset
    private static let onsetTrackingAlpha: Float = 0.9  // smoothing for the "recent average" energy follower

    // MARK: - FFT
    private var log2n:    vDSP_Length
    private var fftSetup: FFTSetup

    // MARK: - Pre-computed N-point Hann window
    private var hannWindow: [Float]  // length N

    // MARK: - Buffers (all pre-allocated at init — no allocations in process())
    // Rolling window of the most recent (fftSize - hopSize) samples of RAW
    // input (never processed/windowed). Combined with the current hop's
    // fresh input, this forms a full N-sample analysis frame each time —
    // needed for any overlap ratio, not just 50%. At 50% overlap this
    // equals exactly one hop (previous behavior); at 75% overlap it's
    // three hops.
    nonisolated(unsafe) private var history: [Float]  // length fftSize - hopSize
    nonisolated(unsafe) private var inputAccum:    [Float]  // length hopSize
    nonisolated(unsafe) private var accumPos:      Int = 0
    nonisolated(unsafe) private var outputOverlap: [Float]  // length N
    nonisolated(unsafe) private var workReal:      [Float]  // length N
    nonisolated(unsafe) private var workImag:      [Float]  // length N — zeroed with vDSP_vclr
    // Per-bin smoothed Wiener gain from the previous frame.
    // Indexed 0..halfN-1. Entry 0 = DC gain, entry 1..halfN-2 = complex bins,
    // entry halfN-1 = Nyquist gain (stored separately but same size array).
    nonisolated(unsafe) private var prevGain: [Float]  // length halfN + 1

    // Minimum statistics noise floor estimator.
    // noisePowerHistory[frame][bin] — circular buffer of per-bin magSq snapshots.
    // noiseFloorEst[bin]            — current per-bin noise floor estimate (magSq units,
    //                                 already scaled to FFT bin magnitude space, i.e.
    //                                 comparable directly to magSq without the halfN factor).
    nonisolated(unsafe) private var noisePowerHistory: [[Float]]  // [historyLength][halfN+1]
    nonisolated(unsafe) private var noiseFloorEst:     [Float]    // length halfN+1
    // noiseFloorEst, smoothed across neighboring frequency bins (3-tap,
    // edge-replicated). True broadband noise has a smooth spectral
    // envelope, so smoothing the estimate itself — not just the resulting
    // gain — removes bin-independent step noise the rolling-minimum
    // estimator produces as frames enter/leave its history window. Pass 1
    // reads this, not noiseFloorEst directly.
    nonisolated(unsafe) private var smoothedNoiseFloor: [Float]  // length halfN+1
    nonisolated(unsafe) private var historyWriteIdx:   Int = 0

    // Raw (unweighted) per-bin magnitude² from the previous frame, used by the
    // decision-directed a priori SNR estimator. Same indexing convention as
    // noiseFloorEst / prevGain / maskingBias: length halfN+1, index 0 = DC,
    // index halfN = Nyquist.
    nonisolated(unsafe) private var prevMagSq: [Float]  // length halfN + 1

    // Slow-following broadband frame energy, used only to detect sudden
    // onsets for the adaptive ddAlpha above. Not per-bin — a single scalar
    // covering the whole frame.
    private var smoothedFrameEnergy: Float = 1e-12

    // Per-bin instantaneous decision-directed target gain, before frequency
    // smoothing. Scratch buffer, fully overwritten every frame.
    nonisolated(unsafe) private var targetGain:   [Float]  // length halfN + 1
    // targetGain after a 3-tap frequency-domain smoothing pass. This is what
    // feeds the existing temporal attack/release smoother.
    nonisolated(unsafe) private var smoothedGain: [Float]  // length halfN + 1

    // MARK: - Output ring
    nonisolated(unsafe) private var outRing:     [Float]    // length N * 2
    nonisolated(unsafe) private var outWritePos: Int = 0
    nonisolated(unsafe) private var outReadPos:  Int = 0

    // MARK: - Parameters (atomic — main-thread writes, audio-thread reads)
    //
    // noiseFloor:  the estimated noise magnitude below which a bin is considered
    //              noise-dominated. Corresponds to the "threshold" from before,
    //              but now feeds the Wiener gain curve rather than a hard gate.
    //              Set this to the RMS level of the noise-only signal in linear
    //              amplitude (not dB). A good starting point is -60 dBFS.
    //
    // wienerFloor: minimum gain applied to any bin (range 0.0–1.0).
    //              Prevents bins from being completely zeroed, which is the
    //              primary cause of musical noise. 0.01 (-40 dB) is a good
    //              default — residual noise is inaudible but phase continuity
    //              is maintained across frames, eliminating the synthetic sound.
    //              Increase toward 0.1 for more natural-sounding processing at
    //              the cost of less noise reduction.

    private let _noiseFloorBits:  ManagedAtomic<Int32>   // linear amplitude
    private let _wienerFloorBits: ManagedAtomic<Int32>   // linear gain 0.0–1.0

    // Profile capture state.
    // captureFramesRemaining counts down from captureLength to 0 on the audio thread.
    // captureAccum accumulates per-bin power sums during capture.
    private let _captureFramesRemaining: ManagedAtomic<Int32>
    nonisolated(unsafe) private var captureAccum: [Double]   // length halfN+1, Double for precision
    private static let captureLength: Int = 96   // ~2 seconds at default settings

    // Flag indicating whether a noise profile has been captured.
    private let _hasCapturedProfile: ManagedAtomic<Int32>

    // Set to 1 automatically when a noise-profile capture completes; cleared by
    // resetNoiseProfile(). While locked, the adaptive minimum-statistics update
    // is skipped entirely and noiseFloorEst stays exactly as captured — this is
    // what the existing startNoiseCapture() doc comment already promises
    // ("locked to the measured profile until resetNoiseProfile() is called"),
    // which the previous implementation did not actually do.
    private let _profileLockActive: ManagedAtomic<Int32>

    /// Mutual-exclusion lock between process() (audio thread) and setMode() (main thread).
    ///
    /// The audio thread calls os_unfair_lock_trylock() — a non-blocking CAS that is
    /// real-time safe. If the lock is held by setMode(), trylock fails immediately and
    /// process() returns silence for that callback, which is inaudible (one frame of
    /// silence during a mode change is imperceptible).
    ///
    /// The main thread calls os_unfair_lock_lock() — a blocking call that waits until
    /// process() releases the lock. Blocking is acceptable on the main thread.
    ///
    /// Allocated on the heap so its address is stable (required by os_unfair_lock).
    private let _processLock: UnsafeMutablePointer<os_unfair_lock>

    // Reduction amount control with psychoacoustic masking bias.
    private let _reductionAmountBits: ManagedAtomic<Int32>

    // Pre-computed per-bin psychoacoustic masking bias (length halfN+1).
    // Values in [0.7, 1.0]: lower = reduce suppression in that bin.
    // Computed once at init from the ATH (absolute threshold of hearing) curve.
    // Applied as: effectiveFloor[k] = wienerFloor ^ (1 / maskingBias[k])
    // (raising the floor to a fractional power keeps it in [floor, 1.0] and
    //  reduces suppression where the ear is sensitive).
    nonisolated(unsafe) private var maskingBias: [Float]   // length halfN+1

    // Frequency-range protection state. Plain instance vars, not atomics —
    // mutated only inside setFrequencyRangeProtection() while holding
    // _processLock (same treatment as fftSize/hopSize/halfN), and read only
    // when rebuilding maskingBias, also under the lock. Never read directly
    // in process() — process() only ever reads the derived maskingBias
    // array.
    private var freqRangeEnabled: Bool = false
    private var protectLowHz: Float = 0.0
    private var protectHighHz: Float = 0.0

    // MARK: - Init
    init(mode: DenoiserMode = .high, sampleRate: Double = 48000.0) {
        self.mode = mode
        self.fftSize = mode.fftSize
        self.hopSize = mode.hopSize
        self.halfN = fftSize / 2
        self.sampleRate = sampleRate

        let N   = self.fftSize
        let hop = self.hopSize
        historyLength = max(16, Int((Self.targetHistoryWindowSeconds * Float(sampleRate)) / Float(hop)))
        log2n    = vDSP_Length(log2(Double(N)).rounded())
        guard let initialSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("SpectralDenoiser: vDSP_create_fftsetup failed for log2n=\(log2n)")
        }
        fftSetup = initialSetup

        // Periodic Hann window (N in denominator).
        // Satisfies COLA-1 at 50% overlap: w[n] + w[n + N/2] = 1.0 for all n.
        // This gives perfect reconstruction on unmodified signals via OLA.
        var hann = [Float](repeating: 0, count: N)
        for i in 0..<N {
            hann[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(N)))
        }
        hannWindow = hann

        // Build ATH-based masking bias curve.
        // The curve reduces Wiener floor gain (i.e. allows less suppression) in the
        // 1–5 kHz region where the ear is most sensitive to artifacts.
        // Formula: bias[k] = 1.0 - 0.30 × sensitivity(f_k)
        // where sensitivity(f) is derived from a simplified ATH approximation.
        var bias = [Float](repeating: 1.0, count: halfN + 1)
        let binHz = Float(sampleRate) / Float(N)
        for k in 0...halfN {
            let f = Float(k) * binHz
            var b = Self.athSensitivity(freqHz: f)
            if freqRangeEnabled {
                b *= Self.rangeProtectionFactor(freqHz: f, lowHz: protectLowHz, highHz: protectHighHz)
            }
            bias[k] = b
        }
        maskingBias = bias

        history       = [Float](repeating: 0, count: N - hop)
        inputAccum    = [Float](repeating: 0, count: hop)
        outputOverlap = [Float](repeating: 0, count: N)
        workReal      = [Float](repeating: 0, count: N)
        workImag      = [Float](repeating: 0, count: N)
        let ringCapacity = max(N * 2, Int(AudioConstants.maxFrameCount) * 2)
        outRing       = [Float](repeating: 0, count: ringCapacity)

        // Initialize smoothed gains to 1.0 — denoiser starts transparent and fades in.
        prevGain = [Float](repeating: 1.0, count: halfN + 1)
        // Initialize previous magnitude² to epsilon for transparent warm-up.
        prevMagSq = [Float](repeating: 1e-12, count: halfN + 1)
        // Initialize gain smoothing buffers (zero-init is fine, fully overwritten each frame).
        targetGain = [Float](repeating: 0.0, count: halfN + 1)
        smoothedGain = [Float](repeating: 0.0, count: halfN + 1)

        // Initialise noise estimator history to a small non-zero value so the
        // Wiener filter is transparent on the first few frames before the estimator warms up.
        // Using a very small power (equiv. to -120 dBFS per bin) avoids false suppression
        // during the initial convergence period (~1.4 seconds).
        let initNoisePower: Float = 1e-12
        noisePowerHistory = [[Float]](
            repeating: [Float](repeating: initNoisePower, count: halfN + 1),
            count: historyLength
        )
        noiseFloorEst = [Float](repeating: initNoisePower, count: halfN + 1)
        smoothedNoiseFloor = [Float](repeating: initNoisePower, count: halfN + 1)
        historyWriteIdx = 0

        // Initialize read pointer to lag one hop behind write pointer
        // to account for the inherent OLA latency of one analysis frame.
        outWritePos = 0
        outReadPos  = outRing.count - hop

        // Default: noise floor = -60 dBFS, Wiener floor = 0.01 (-40 dB)
        _noiseFloorBits  = ManagedAtomic(Self.floatBits(pow(10.0, -60.0 / 20.0)))
        _wienerFloorBits = ManagedAtomic(Self.floatBits(0.01))
        _captureFramesRemaining = ManagedAtomic(Int32(0))
        _hasCapturedProfile = ManagedAtomic(Int32(0))
        _profileLockActive = ManagedAtomic(Int32(0))
        _processLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        _processLock.initialize(to: os_unfair_lock_s())
        captureAccum = [Double](repeating: 0.0, count: halfN + 1)

        // Default reduction amount: 50%
        _reductionAmountBits = ManagedAtomic(Self.floatBits(0.5))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        _processLock.deinitialize(count: 1)
        _processLock.deallocate()
    }

    // MARK: - Helper Methods

    /// Rebuilds the ATH-based masking bias curve using the current sample rate.
    /// The curve reduces Wiener floor gain (i.e. allows less suppression) in the
    /// 1–5 kHz region where the ear is most sensitive to artifacts.
    private func rebuildMaskingBias() {
        let N = fftSize
        var bias = [Float](repeating: 1.0, count: halfN + 1)
        let binHz = Float(sampleRate) / Float(N)
        for k in 0...halfN {
            let f = Float(k) * binHz
            var b = Self.athSensitivity(freqHz: f)
            if freqRangeEnabled {
                b *= Self.rangeProtectionFactor(freqHz: f, lowHz: protectLowHz, highHz: protectHighHz)
            }
            bias[k] = b
        }
        maskingBias = bias
    }

    /// Updates the sample rate and rebuilds the masking bias curve.
    func updateSampleRate(_ newSampleRate: Double) {
        sampleRate = newSampleRate
        rebuildMaskingBias()
        // Use stored ms values directly — no reverse-derivation that would drift on repeated calls.
        setGainSmoothingMs(attackMs: gainAttackMs, releaseMs: gainReleaseMs, sampleRate: newSampleRate)
        // Per-bin noise floor estimates are in the old frequency scale; discard them.
        reset()
    }

    // MARK: - Main Thread API

    /// Returns whether a noise profile has been captured.
    var hasCapturedProfile: Bool {
        _hasCapturedProfile.load(ordering: .relaxed) != 0
    }

    /// Returns true once a captured noise profile is active and locked — the
    /// adaptive estimator is not running and noiseFloorEst is frozen to the
    /// measured profile.
    var isProfileLocked: Bool {
        _profileLockActive.load(ordering: .relaxed) != 0
    }

    /// Progress of an in-progress capture, 0.0...1.0. Returns 0.0 when not
    /// currently capturing.
    var captureProgress: Float {
        let remaining = _captureFramesRemaining.load(ordering: .relaxed)
        guard remaining > 0 else { return 0.0 }
        return 1.0 - Float(remaining) / Float(Self.captureLength)
    }

    /// Sets the noise floor in dBFS.
    /// Bins whose magnitude is at or below this level are considered noise-dominated.
    /// -60 dBFS is a reasonable default for hiss removal; raise to -40 dBFS for
    /// more aggressive suppression of low-level room noise.
    func setNoiseFloorDB(_ db: Float) {
        _noiseFloorBits.store(Self.floatBits(pow(10.0, db / 20.0)), ordering: .relaxed)
    }

    /// Sets the Wiener gain floor (0.0–1.0, default 0.01 = -40 dB).
    /// This is the minimum gain applied to any bin regardless of its SNR.
    /// It prevents bins from being completely zeroed, which is the primary cause
    /// of musical noise. Lower values give more attenuation at the cost of
    /// increased residual musical noise artifacts.
    func setWienerFloor(_ floor: Float) {
        _wienerFloorBits.store(Self.floatBits(max(0.0, min(1.0, floor))), ordering: .relaxed)
    }

    /// Starts a noise profile capture. Call during a noise-only period
    /// (lead-in groove, tape leader, silence between tracks).
    /// Capture completes after ~2 seconds; the per-bin noise floor estimate
    /// is then locked to the measured profile until resetNoiseProfile() is called.
    func startNoiseCapture() {
        captureAccum.withUnsafeMutableBufferPointer {
            vDSP_vclrD($0.baseAddress!, 1, vDSP_Length(halfN + 1))
        }
        _captureFramesRemaining.store(Int32(Self.captureLength), ordering: .relaxed)
    }

    /// Returns true while a capture is in progress.
    var isCapturing: Bool {
        _captureFramesRemaining.load(ordering: .relaxed) > 0
    }

    /// Clears the captured profile, returning the estimator to adaptive mode.
    func resetNoiseProfile() {
        _captureFramesRemaining.store(0, ordering: .relaxed)
        _profileLockActive.store(0, ordering: .relaxed)
        // Re-initialise the history so the adaptive estimator takes over immediately.
        reset()
    }

    /// Sets the noise reduction amount. 0.0 = near-transparent, 1.0 = maximum.
    /// This is the primary user-facing control; it maps to an effective Wiener floor
    /// using a perceptually linear exponential curve.
    func setReductionAmount(_ amount: Float) {
        _reductionAmountBits.store(
            Self.floatBits(amount.clamped(to: 0.0...1.0)),
            ordering: .relaxed
        )
    }

    /// Updates gain-smoothing time constants. Call from the main thread only.
    /// - Parameters:
    ///   - attackMs:  Gain attack time in milliseconds (how quickly gain rises to unity).
    ///   - releaseMs: Gain release time in milliseconds (how quickly gain falls).
    ///   - sampleRate: Current sample rate (used together with hopSize).
    func setGainSmoothingMs(attackMs: Float, releaseMs: Float, sampleRate: Double) {
        gainAttackMs  = attackMs
        gainReleaseMs = releaseMs
        let frameMs = Float(hopSize) / Float(sampleRate) * 1000.0
        gainAttackAlpha  = max(0.0, min(0.999, Float(exp(-Double(frameMs / max(attackMs,  0.1))))))
        gainReleaseAlpha = max(0.0, min(0.999, Float(exp(-Double(frameMs / max(releaseMs, 0.1))))))
    }

    /// Changes the processing mode. This reinitialises all internal state and
    /// must only be called from the main thread while the audio engine is stopped
    /// or while the denoiser is bypassed.
    func setMode(_ newMode: DenoiserMode, sampleRate: Double) {
        // Stop any in-progress noise capture before acquiring the lock.
        // This prevents the audio thread from writing into captureAccum during reallocation.
        _captureFramesRemaining.store(0, ordering: .sequentiallyConsistent)

        // Block until the audio thread releases the lock (i.e. finishes its current
        // process() call). This is safe on the main thread — it is not real-time.
        // After lock() returns, we are guaranteed that no process() call is executing.
        os_unfair_lock_lock(_processLock)
        defer { os_unfair_lock_unlock(_processLock) }

        let N   = newMode.fftSize
        let hop = newMode.hopSize

        mode    = newMode
        fftSize = N
        hopSize = hop
        halfN   = N / 2
        self.sampleRate = sampleRate
        historyLength = max(16, Int((Self.targetHistoryWindowSeconds * Float(sampleRate)) / Float(hop)))

        // Destroy old FFT setup before replacing it to avoid a resource leak.
        vDSP_destroy_fftsetup(fftSetup)
        log2n = vDSP_Length(log2(Double(N)).rounded())
        guard let newSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("SpectralDenoiser: vDSP_create_fftsetup failed for log2n=\(log2n)")
        }
        fftSetup = newSetup

        // Rebuild Hann window.
        var hann = [Float](repeating: 0, count: N)
        for i in 0..<N {
            hann[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(N)))
        }
        hannWindow = hann

        rebuildMaskingBias()

        // Reallocate all buffers.
        // Ring buffer must be large enough for the worst-case HAL callback size.
        let ringCapacity = max(N * 2, Int(AudioConstants.maxFrameCount) * 2)
        history       = [Float](repeating: 0, count: N - hop)
        inputAccum    = [Float](repeating: 0, count: hop)
        outputOverlap = [Float](repeating: 0, count: N)
        workReal      = [Float](repeating: 0, count: N)
        workImag      = [Float](repeating: 0, count: N)
        outRing       = [Float](repeating: 0, count: ringCapacity)
        prevGain      = [Float](repeating: 1.0, count: halfN + 1)
        prevMagSq     = [Float](repeating: 1e-12, count: halfN + 1)
        targetGain    = [Float](repeating: 0.0, count: halfN + 1)
        smoothedGain  = [Float](repeating: 0.0, count: halfN + 1)

        let initNoisePower: Float = 1e-12
        noisePowerHistory = [[Float]](
            repeating: [Float](repeating: initNoisePower, count: halfN + 1),
            count: historyLength
        )
        noiseFloorEst = [Float](repeating: initNoisePower, count: halfN + 1)
        smoothedNoiseFloor = [Float](repeating: initNoisePower, count: halfN + 1)
        captureAccum  = [Double](repeating: 0.0, count: halfN + 1)

        // Clear capture flags — a captured profile is meaningless after resolution change.
        _hasCapturedProfile.store(0, ordering: .relaxed)
        _profileLockActive.store(0, ordering: .relaxed)

        // Reset all processing state.
        reset()
    }

    /// Main-thread only. Updates the protected frequency band and rebuilds
    /// maskingBias under the same lock setMode() uses, since process() reads
    /// maskingBias every frame under trylock.
    func setFrequencyRangeProtection(enabled: Bool, lowHz: Float, highHz: Float) {
        os_unfair_lock_lock(_processLock)
        defer { os_unfair_lock_unlock(_processLock) }
        freqRangeEnabled = enabled
        let lo = max(0, min(lowHz, highHz))
        let hi = max(lo, highHz)
        protectLowHz = lo
        protectHighHz = hi
        rebuildMaskingBias()
    }

    // MARK: - Audio Thread

    /// Smooths noiseFloorEst across neighboring frequency bins (3-tap,
    /// edge-replicated) into smoothedNoiseFloor. Call whenever
    /// noiseFloorEst changes: once per frame during adaptive tracking, and
    /// once when a capture completes.
    @inline(__always)
    private func smoothNoiseFloorAcrossFrequency() {
        smoothedNoiseFloor[0] = 0.75 * noiseFloorEst[0] + 0.25 * noiseFloorEst[1]
        for k in 1..<halfN {
            smoothedNoiseFloor[k] = 0.25 * noiseFloorEst[k - 1]
                                   + 0.50 * noiseFloorEst[k]
                                   + 0.25 * noiseFloorEst[k + 1]
        }
        smoothedNoiseFloor[halfN] = 0.25 * noiseFloorEst[halfN - 1] + 0.75 * noiseFloorEst[halfN]
    }

    func reset() {
        let N   = fftSize
        let hop = hopSize
        workReal.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N)) }
        workImag.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N)) }
        history.withUnsafeMutableBufferPointer       { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N - hop)) }
        inputAccum.withUnsafeMutableBufferPointer    { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(hop)) }
        outputOverlap.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N)) }
        outRing.withUnsafeMutableBufferPointer       { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(outRing.count)) }
        outWritePos = 0
        outReadPos  = outRing.count - hop
        accumPos    = 0
        // Reset smoothed gains to 1.0 so the denoiser opens transparently after a reset.
        for i in 0..<prevGain.count { prevGain[i] = 1.0 }
        // Reset previous magnitude² to epsilon.
        for i in 0..<prevMagSq.count { prevMagSq[i] = 1e-12 }
        smoothedFrameEnergy = 1e-12
        // Reset noise estimator history.
        let initNoisePower: Float = 1e-12
        for f in 0..<historyLength {
            for k in 0...halfN { noisePowerHistory[f][k] = initNoisePower }
        }
        for k in 0...halfN { noiseFloorEst[k] = initNoisePower }
        for k in 0...halfN { smoothedNoiseFloor[k] = initNoisePower }
        historyWriteIdx = 0
    }

    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, count: Int) {
        // Attempt to acquire the lock non-blocking. If setMode() currently holds it
        // (i.e. a mode change is in progress), return silence for this callback.
        // trylock is a single CAS — it never blocks and is real-time safe.
        guard os_unfair_lock_trylock(_processLock) else {
            vDSP_vclr(buffer, 1, vDSP_Length(count))
            return
        }
        defer { os_unfair_lock_unlock(_processLock) }

        let N          = fftSize
        let hop        = hopSize
        let halfN      = self.halfN
        let ringSize   = outRing.count

        let amount = Self.bitsToFloat(_reductionAmountBits.load(ordering: .relaxed))
        // Preset ceiling: the deepest gain floor this preset will ever reach, even
        // at 100% reduction amount. Was previously hardcoded to 0.01 — now reads
        // the value set via setWienerFloor() / the active DenoiserPreset.
        let presetFloorCeiling = max(Self.bitsToFloat(_wienerFloorBits.load(ordering: .relaxed)), 1e-4)
        // Exponential mapping: 0% → floor≈0.90 (−0.9 dB), 100% → presetFloorCeiling.
        let wienerFloor = 0.90 * pow(presetFloorCeiling / 0.90, amount)

        // User-set noise floor safety threshold (manual floor under adaptive/captured estimate).
        let userFloorLinear = Self.bitsToFloat(_noiseFloorBits.load(ordering: .relaxed))
        let userFloorPow = userFloorLinear * userFloorLinear  // amplitude → power

        var srcPos = 0
        while srcPos < count {
            let chunk = min(hop - accumPos, count - srcPos)
            for i in 0..<chunk { inputAccum[accumPos + i] = buffer[srcPos + i] }
            accumPos += chunk
            srcPos   += chunk

            if accumPos == hop {

                // Form the full N-point analysis frame [history | currentHop]
                // and apply the N-point Hann window. history holds exactly
                // (N - hop) samples, so this always fills the whole N-length
                // buffer with real input regardless of overlap ratio.
                let histLen = N - hop
                for i in 0..<histLen { workReal[i]          = history[i]    * hannWindow[i] }
                for i in 0..<hop     { workReal[histLen + i] = inputAccum[i] * hannWindow[histLen + i] }

                // FIX 3: Zero workImag with vDSP_vclr — no Array allocation.
                workImag.withUnsafeMutableBufferPointer {
                    vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N))
                }

                // Slide history forward by one hop: drop the oldest hop
                // samples, append this frame's raw input as the newest hop.
                // At 50% overlap (histLen == hop) this is a straight
                // replace, identical to the previous prevHop behavior; at
                // 75% overlap it's a partial shift + append.
                if histLen > hop {
                    history.withUnsafeMutableBufferPointer { buf in
                        let base = buf.baseAddress!
                        memmove(base, base + hop, MemoryLayout<Float>.stride * (histLen - hop))
                    }
                    for i in 0..<hop { history[histLen - hop + i] = inputAccum[i] }
                } else {
                    for i in 0..<hop { history[i] = inputAccum[i] }
                }
                for i in 0..<hop { inputAccum[i] = 0 }
                accumPos = 0

                workReal.withUnsafeMutableBufferPointer { rp in
                    workImag.withUnsafeMutableBufferPointer { ip in
                        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        rp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: halfN) { cBuf in
                            vDSP_ctoz(cBuf, 1, &sc, 1, vDSP_Length(halfN))
                        }

                        // Forward FFT.
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))

                        // ── Minimum statistics noise floor update ─────────────────────────────────
                        //
                        // Record current per-bin power into the circular history buffer.
                        // Then recompute the per-bin minimum across all history frames.
                        // Apply bias correction so the estimate represents the true mean noise power.
                        //
                        // noisePowerHistory values are in raw FFT magnitude² units (no halfN scaling
                        // needed — the noiseFloorEst is used directly against magSq below).

                        if _profileLockActive.load(ordering: .relaxed) == 0 {
                            // DC bin
                            noisePowerHistory[historyWriteIdx][0]      = rp[0] * rp[0]
                            // Nyquist bin
                            noisePowerHistory[historyWriteIdx][halfN]  = ip[0] * ip[0]
                            // Complex bins 1..halfN-1
                            for k in 1..<halfN {
                                noisePowerHistory[historyWriteIdx][k] = rp[k] * rp[k] + ip[k] * ip[k]
                            }

                            // Update rolling minimum for each bin and apply bias correction.
                            let bias = Self.minStatsBias
                            for k in 0...halfN {
                                var minPow = noisePowerHistory[0][k]
                                for f in 1..<historyLength {
                                    let p = noisePowerHistory[f][k]
                                    if p < minPow { minPow = p }
                                }
                                noiseFloorEst[k] = minPow * bias
                            }
                            smoothNoiseFloorAcrossFrequency()

                            // Advance circular write pointer.
                            historyWriteIdx = (historyWriteIdx + 1) % historyLength
                        }

                        // Profile capture: if active, accumulate per-bin power.
                        let captureRemaining = _captureFramesRemaining.load(ordering: .relaxed)
                        if captureRemaining > 0 {
                            captureAccum[0]     += Double(rp[0] * rp[0])
                            captureAccum[halfN] += Double(ip[0] * ip[0])
                            for k in 1..<halfN {
                                captureAccum[k] += Double(rp[k] * rp[k] + ip[k] * ip[k])
                            }
                            let newRemaining = captureRemaining - 1
                            _captureFramesRemaining.store(newRemaining, ordering: .relaxed)
                            if newRemaining == 0 {
                                // Capture complete: write averaged per-bin power to noiseFloorEst,
                                // overriding the rolling minimum. Also seed the history buffer with
                                // this profile so the adaptive estimator starts from the right baseline.
                                let frameCount = Double(Self.captureLength)
                                for k in 0...halfN {
                                    let avgPow = Float(captureAccum[k] / frameCount)
                                    noiseFloorEst[k] = avgPow
                                    for f in 0..<historyLength {
                                        noisePowerHistory[f][k] = avgPow
                                    }
                                }
                                smoothNoiseFloorAcrossFrequency()
                                // Mark that a profile has been captured
                                _hasCapturedProfile.store(1, ordering: .relaxed)
                                // Lock the profile — disable adaptive updates
                                _profileLockActive.store(1, ordering: .relaxed)
                            }
                        }

                        // ── Pass 1: decision-directed target gain per bin ──────────────────────
                        //
                        // Standard spectral-subtraction musical-noise fix (Ephraim & Malah, 1984):
                        // instead of computing the Wiener gain directly from the instantaneous
                        // (a posteriori) SNR each frame, smooth the SNR estimate itself using the
                        // previous frame's *applied* gain and magnitude. This is what actually
                        // suppresses musical noise — the temporal attack/release smoother below
                        // only smooths the already-computed gain, which is a weaker effect.

                        // Broadband onset detection: total frame energy vs. a slow-following
                        // recent average. energyRatioDB > 0 means this frame is louder than
                        // recent history; the further above onsetRatioFloorDB it is, the more
                        // ddAlpha shifts toward the fast-responding onsetAlpha for this frame.
                        var frameEnergy: Float = (rp[0] * rp[0]) + (ip[0] * ip[0])
                        for k in 1..<halfN {
                            frameEnergy += rp[k] * rp[k] + ip[k] * ip[k]
                        }
                        let energyRatioDB = 10.0 * log10(max(frameEnergy, 1e-20) / max(smoothedFrameEnergy, 1e-20))
                        let onsetStrength = ((energyRatioDB - Self.onsetRatioFloorDB)
                                             / (Self.onsetRatioCeilDB - Self.onsetRatioFloorDB)).clamped(to: 0.0...1.0)
                        let ddAlpha = Self.decisionDirectedAlpha
                                    - onsetStrength * (Self.decisionDirectedAlpha - Self.onsetAlpha)
                        smoothedFrameEnergy = Self.onsetTrackingAlpha * smoothedFrameEnergy
                                             + (1.0 - Self.onsetTrackingAlpha) * frameEnergy

                        @inline(__always)
                        func decisionDirectedTarget(magSq: Float, floorPow: Float,
                                                     prevG: Float, prevMag: Float,
                                                     binFloor: Float) -> Float {
                            let safeFloor    = max(floorPow, 1e-20)
                            let aPosteriori  = magSq / safeFloor
                            let prevSignalPow = prevG * prevG * prevMag
                            let aPriori = ddAlpha * (prevSignalPow / safeFloor)
                                        + (1.0 - ddAlpha) * max(aPosteriori - 1.0, 0.0)
                            return max(binFloor, aPriori / (aPriori + 1.0))
                        }

                        // DC bin
                        do {
                            let magSq    = rp[0] * rp[0]
                            let floorPow = max(smoothedNoiseFloor[0], userFloorPow)
                            let binFloor = pow(wienerFloor, maskingBias[0])
                            targetGain[0] = decisionDirectedTarget(magSq: magSq, floorPow: floorPow,
                                                                    prevG: prevGain[0], prevMag: prevMagSq[0],
                                                                    binFloor: binFloor)
                            prevMagSq[0] = magSq
                        }
                        // Nyquist bin
                        do {
                            let magSq    = ip[0] * ip[0]
                            let floorPow = max(smoothedNoiseFloor[halfN], userFloorPow)
                            let binFloor = pow(wienerFloor, maskingBias[halfN])
                            targetGain[halfN] = decisionDirectedTarget(magSq: magSq, floorPow: floorPow,
                                                                        prevG: prevGain[halfN], prevMag: prevMagSq[halfN],
                                                                        binFloor: binFloor)
                            prevMagSq[halfN] = magSq
                        }
                        // Complex bins 1..<halfN
                        for k in 1..<halfN {
                            let magSq    = rp[k] * rp[k] + ip[k] * ip[k]
                            let floorPow = max(smoothedNoiseFloor[k], userFloorPow)
                            let binFloor = pow(wienerFloor, maskingBias[k])
                            targetGain[k] = decisionDirectedTarget(magSq: magSq, floorPow: floorPow,
                                                                    prevG: prevGain[k], prevMag: prevMagSq[k],
                                                                    binFloor: binFloor)
                            prevMagSq[k] = magSq
                        }

                        // ── Pass 2: frequency-domain gain smoothing (3-tap, edge-replicated) ───
                        //
                        // Suppresses isolated single-bin gain spikes/dips relative to their
                        // neighbors — a major contributor to "musical noise" / roughness that
                        // per-bin temporal smoothing alone cannot fix. Fixed light 3-tap kernel,
                        // not exposed to the user (same design precedent as the ATH masking bias
                        // curve and minimum-statistics bias constant already in this file).
                        smoothedGain[0] = 0.75 * targetGain[0] + 0.25 * targetGain[1]
                        for k in 1..<halfN {
                            smoothedGain[k] = 0.25 * targetGain[k - 1]
                                             + 0.50 * targetGain[k]
                                             + 0.25 * targetGain[k + 1]
                        }
                        smoothedGain[halfN] = 0.25 * targetGain[halfN - 1] + 0.75 * targetGain[halfN]

                        // ── Pass 3: temporal attack/release smoothing + apply (existing logic) ──
                        let attackAlpha  = gainAttackAlpha
                        let releaseAlpha = gainReleaseAlpha

                        // DC bin
                        do {
                            let target = smoothedGain[0]
                            let alpha  = target > prevGain[0] ? attackAlpha : releaseAlpha
                            let gain   = alpha * prevGain[0] + (1.0 - alpha) * target
                            prevGain[0] = gain
                            rp[0]      *= gain
                        }
                        // Nyquist bin
                        do {
                            let target = smoothedGain[halfN]
                            let alpha  = target > prevGain[halfN] ? attackAlpha : releaseAlpha
                            let gain   = alpha * prevGain[halfN] + (1.0 - alpha) * target
                            prevGain[halfN] = gain
                            ip[0]          *= gain
                        }
                        // Complex bins 1..<halfN
                        for k in 1..<halfN {
                            let target = smoothedGain[k]
                            let alpha  = target > prevGain[k] ? attackAlpha : releaseAlpha
                            let gain   = alpha * prevGain[k] + (1.0 - alpha) * target
                            prevGain[k] = gain
                            rp[k]      *= gain
                            ip[k]      *= gain
                        }

                        // Inverse FFT.
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))

                        // IFFT normalization with COLA correction.
                        // vDSP_fft_zrip round-trip scale: forward ×2, inverse ×N/2 → product = N.
                        // Combined with COLA correction for overlap mode.
                        var scale = mode.normScale
                        vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1,
                                   vDSP_Length(halfN))
                        vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1,
                                   vDSP_Length(halfN))

                        // Convert split-complex back to interleaved real (ztoc).
                        rp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: halfN) { cBuf in
                            vDSP_ztoc(&sc, 1, cBuf, 1, vDSP_Length(halfN))
                        }
                    }
                }

                // Overlap-add into outputOverlap.
                for i in 0..<N { outputOverlap[i] += workReal[i] }

                // Flush the first hop to the output ring.
                for i in 0..<hop {
                    outRing[outWritePos] = outputOverlap[i]
                    outWritePos = (outWritePos + 1) % ringSize
                }

                // Shift overlap buffer: move second half to first half (memmove; regions may overlap).
                outputOverlap.withUnsafeMutableBufferPointer { buf in
                    let base = buf.baseAddress!
                    // Shift the remaining (N - hop) samples to the front of the buffer.
                    memmove(base, base + hop, MemoryLayout<Float>.stride * (N - hop))
                    // Zero the last `hop` positions to prepare for the next OLA frame.
                    vDSP_vclr(base + (N - hop), 1, vDSP_Length(hop))
                }
            }
        }

        // Drain output ring to caller's buffer.
        for i in 0..<count {
            buffer[i]            = outRing[outReadPos]
            outRing[outReadPos]  = 0
            outReadPos           = (outReadPos + 1) % ringSize
        }
    }

    // MARK: - Helpers
    private static func floatBits(_ f: Float) -> Int32 {
        Int32(bitPattern: f.bitPattern)
    }
    private static func bitsToFloat(_ bits: Int32) -> Float {
        Float(bitPattern: UInt32(bitPattern: bits))
    }

    /// Returns a per-bin suppression bias in [0.70, 1.00] based on a simplified
    /// ATH curve. Value of 1.0 = no bias (full suppression allowed).
    /// Value of 0.70 = 30% less suppression (sensitive region).
    private static func athSensitivity(freqHz: Float) -> Float {
        guard freqHz >= 20, freqHz <= 20_000 else { return 0.70 }
        let f = freqHz / 1000.0  // kHz
        // Simplified Moore ATH approximation (dB SPL):
        let athDB = 3.64 * pow(f, -0.8)
                   - 6.5  * exp(-0.6 * pow(f - 3.3, 2))
                   + 1e-3 * pow(f, 4.0)
        // Normalise to [0,1]: 0 dB ≈ most sensitive, 80 dB ≈ least.
        let sensitivity = (1.0 - (athDB / 80.0)).clamped(to: 0.0...1.0)
        // Bias: full suppression in insensitive regions, 30% less in sensitive regions.
        return 1.0 - 0.30 * sensitivity
    }

    /// Returns 1.0 outside [lowHz, highHz] (normal suppression allowed),
    /// 0.0 inside it (fully protected — no suppression possible there),
    /// with a half-octave smooth taper at each edge to avoid an audible
    /// seam. Setting lowHz to 0 gives a classic single high-pass cutoff
    /// (protect everything below highHz); setting highHz to the Nyquist
    /// frequency gives a single low-pass cutoff (protect everything above
    /// lowHz); interior values on both edges protect a middle band while
    /// leaving both spectral extremes processed.
    private static func rangeProtectionFactor(freqHz: Float, lowHz: Float, highHz: Float) -> Float {
        guard highHz > lowHz else { return 1.0 }  // degenerate band — no-op
        let transitionOctaves: Float = 0.5
        if freqHz < lowHz {
            guard lowHz > 0 else { return 0.0 }
            let octavesBelow = log2(max(lowHz, 1.0) / max(freqHz, 1.0))
            return (octavesBelow / transitionOctaves).clamped(to: 0.0...1.0)
        } else if freqHz > highHz {
            let octavesAbove = log2(max(freqHz, 1.0) / max(highHz, 1.0))
            return (octavesAbove / transitionOctaves).clamped(to: 0.0...1.0)
        } else {
            return 0.0  // inside the protected band
        }
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
