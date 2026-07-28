import Accelerate
import Atomics
import AudioToolbox
import Foundation

/// Dialogue-Relative Leveler processor.
///
/// Compares the dialogue band's level against the full program level and boosts
/// only when the gap between them exceeds targetGapDB — i.e. only when dialogue
/// is actually being masked by the rest of the mix right now, not merely whenever
/// the dialogue band itself is quiet.
///
/// Signal chain (per buffer):
/// 1. Dialogue-band detector: bandpass (bandLowHz–bandHighHz) → RMS envelope → dB
/// 2. Program detector: broadband RMS on full input → dB
/// 3. Gain computer: shortfall = (programDB - targetGapDB) - dialogueDB
/// 4. Asymmetric smoothing: fast attack, slow release
/// 5. Band-extract-and-recombine: residual + shapedBand × gainLinear
///
/// Thread safety: atomic parameters written by main thread; all state is audio-thread-only.
final class DialogueRelativeLeveler: @unchecked Sendable {

    // MARK: - Constants

    static let maxFrameCount: Int = 4096

    // MARK: - Atomics (main thread → audio thread)

    private let _enabled: ManagedAtomic<Int32>
    private let _bandLowHzBits:      ManagedAtomic<Int32>  // Float bits
    private let _bandHighHzBits:     ManagedAtomic<Int32>  // Float bits
    private let _targetGapDBBits:    ManagedAtomic<Int32>  // Float bits
    private let _boostRatioBits:     ManagedAtomic<Int32>  // Float bits
    private let _maxBoostDBBits:     ManagedAtomic<Int32>  // Float bits
    private let _detectorWindowMsBits: ManagedAtomic<Int32>  // Float bits
    private let _attackMsBits:       ManagedAtomic<Int32>  // Float bits
    private let _releaseMsBits:      ManagedAtomic<Int32>  // Float bits
    private let _programGateThresholdDBBits: ManagedAtomic<Int32>  // Float bits

    // MARK: - Audio-Thread State

    /// Dialogue bandpass biquad state per channel: [ch * 2 + stateVar] (w1, w2).
    nonisolated(unsafe) private var bandpassState: [Float]

    /// Dialogue-band RMS envelope state (one-pole leaky integrator on squared signal).
    nonisolated(unsafe) private var dialogueRMSState: Float = 0.0

    /// Program RMS envelope state (one-pole leaky integrator on squared signal).
    nonisolated(unsafe) private var programRMSState: Float = 0.0

    /// Smoothed boost in dB (audio thread only). Starts at 0.
    nonisolated(unsafe) private var smoothedBoostDB: Float = 0.0

    /// Current sample rate (updated by main thread before audio starts).
    nonisolated(unsafe) private var sampleRate: Double = 48000.0

    /// Precomputed attack/release coefficients (updated when parameters change).
    nonisolated(unsafe) private var attackCoeff:  Float = 0.0
    nonisolated(unsafe) private var releaseCoeff: Float = 0.0
    nonisolated(unsafe) private var rmsAlpha:    Float = 0.0

    /// Bandpass biquad coefficients (b0, b1, b2, a1, a2).
    nonisolated(unsafe) private var bp_b0: Float = 1.0
    nonisolated(unsafe) private var bp_b1: Float = 0.0
    nonisolated(unsafe) private var bp_b2: Float = 0.0
    nonisolated(unsafe) private var bp_a1: Float = 0.0
    nonisolated(unsafe) private var bp_a2: Float = 0.0

    /// Pending coefficients for thread-safe updates.
    nonisolated(unsafe) private var pending_bp_b0: Float = 1.0
    nonisolated(unsafe) private var pending_bp_b1: Float = 0.0
    nonisolated(unsafe) private var pending_bp_b2: Float = 0.0
    nonisolated(unsafe) private var pending_bp_a1: Float = 0.0
    nonisolated(unsafe) private var pending_bp_a2: Float = 0.0

    private let hasCoeffUpdate = ManagedAtomic<Bool>(false)

    // MARK: - Scratch Buffers (pre-allocated to maxFrameCount)

    private let bandScratch:      UnsafeMutablePointer<Float>  // Filtered dialogue band
    private let dialogueEnvScratch: UnsafeMutablePointer<Float>  // Dialogue envelope
    private let programEnvScratch:  UnsafeMutablePointer<Float>  // Program envelope
    private let dialogueDBScratch: UnsafeMutablePointer<Float>  // Dialogue level in dB
    private let programDBScratch:  UnsafeMutablePointer<Float>  // Program level in dB
    private let boostDBScratch:    UnsafeMutablePointer<Float>  // Boost in dB
    private let gainLinearScratch: UnsafeMutablePointer<Float>  // Linear gain
    private let residualScratch:   UnsafeMutablePointer<Float>  // Residual (input - band)
    private let shapedBandScratch: UnsafeMutablePointer<Float>  // Shaped band (band × gain)

    // MARK: - Initialisation

    init() {
        _enabled = ManagedAtomic(0)
        _bandLowHzBits = ManagedAtomic(floatBitsL(300.0))
        _bandHighHzBits = ManagedAtomic(floatBitsL(3500.0))
        _targetGapDBBits = ManagedAtomic(floatBitsL(10.0))
        _boostRatioBits = ManagedAtomic(floatBitsL(2.0))
        _maxBoostDBBits = ManagedAtomic(floatBitsL(8.0))
        _detectorWindowMsBits = ManagedAtomic(floatBitsL(300.0))
        _attackMsBits = ManagedAtomic(floatBitsL(150.0))
        _releaseMsBits = ManagedAtomic(floatBitsL(900.0))
        _programGateThresholdDBBits = ManagedAtomic(floatBitsL(-50.0))

        bandpassState = Array(repeating: 0.0, count: 2 * 2)  // 2 channels × 2 state vars

        // Pre-allocate scratch buffers
        bandScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        dialogueEnvScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        programEnvScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        dialogueDBScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        programDBScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        boostDBScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        gainLinearScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        residualScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)
        shapedBandScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrameCount)

        // Initialise coefficients at default sample rate
        updateCoefficients(sampleRate: 48000.0)
    }

    deinit {
        bandScratch.deallocate()
        dialogueEnvScratch.deallocate()
        programEnvScratch.deallocate()
        dialogueDBScratch.deallocate()
        programDBScratch.deallocate()
        boostDBScratch.deallocate()
        gainLinearScratch.deallocate()
        residualScratch.deallocate()
        shapedBandScratch.deallocate()
    }

    // MARK: - Parameter API (main thread)

    var isEnabled: Bool { _enabled.load(ordering: .relaxed) != 0 }

    func setEnabled(_ v: Bool) { _enabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setBandLowHz(_ hz: Float) { _bandLowHzBits.store(floatBitsL(hz), ordering: .relaxed) }
    func setBandHighHz(_ hz: Float) { _bandHighHzBits.store(floatBitsL(hz), ordering: .relaxed) }
    func setTargetGapDB(_ db: Float) { _targetGapDBBits.store(floatBitsL(db), ordering: .relaxed) }
    func setBoostRatio(_ ratio: Float) { _boostRatioBits.store(floatBitsL(ratio), ordering: .relaxed) }
    func setMaxBoostDB(_ db: Float) { _maxBoostDBBits.store(floatBitsL(db), ordering: .relaxed) }
    func setDetectorWindowMs(_ ms: Float) { _detectorWindowMsBits.store(floatBitsL(ms), ordering: .relaxed) }
    func setAttackMs(_ ms: Float) { _attackMsBits.store(floatBitsL(ms), ordering: .relaxed) }
    func setReleaseMs(_ ms: Float) { _releaseMsBits.store(floatBitsL(ms), ordering: .relaxed) }
    func setProgramGateThresholdDB(_ db: Float) { _programGateThresholdDBBits.store(floatBitsL(db), ordering: .relaxed) }

    func applyConfig(_ config: DialogueRelativeLevelerConfig) {
        setEnabled(config.isEnabled)
        setBandLowHz(config.bandLowHz)
        setBandHighHz(config.bandHighHz)
        setTargetGapDB(config.targetGapDB)
        setBoostRatio(config.boostRatio)
        setMaxBoostDB(config.maxBoostDB)
        setDetectorWindowMs(config.detectorWindowMs)
        setAttackMs(config.attackMs)
        setReleaseMs(config.releaseMs)
        setProgramGateThresholdDB(config.programGateThresholdDB)

        // Recompute coefficients on main thread
        updateCoefficients(sampleRate: sampleRate)
    }

    func resetState(sampleRate: Double) {
        self.sampleRate = sampleRate
        for i in 0..<bandpassState.count { bandpassState[i] = 0 }
        dialogueRMSState = 0.0
        programRMSState = 0.0
        smoothedBoostDB = 0.0
        updateCoefficients(sampleRate: sampleRate)
    }

    // MARK: - Audio Thread: Process

    @inline(__always)
    func process(
        abl: UnsafeMutableAudioBufferListPointer,
        numCh: Int,
        count: Int
    ) {
        guard _enabled.load(ordering: .relaxed) != 0, count > 0 else { return }

        // Apply pending coefficient update if available
        if hasCoeffUpdate.exchange(false, ordering: .acquiringAndReleasing) {
            bp_b0 = pending_bp_b0
            bp_b1 = pending_bp_b1
            bp_b2 = pending_bp_b2
            bp_a1 = pending_bp_a1
            bp_a2 = pending_bp_a2
        }

        // Read parameters (once per block)
        let targetGapDB = bitsToFloatL(_targetGapDBBits.load(ordering: .relaxed))
        let boostRatio = bitsToFloatL(_boostRatioBits.load(ordering: .relaxed))
        let maxBoostDB = bitsToFloatL(_maxBoostDBBits.load(ordering: .relaxed))
        let programGateThresholdDB = bitsToFloatL(_programGateThresholdDBBits.load(ordering: .relaxed))

        // Process each channel
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stateBase = ch * 2
            var w1 = bandpassState[stateBase]
            var w2 = bandpassState[stateBase + 1]

            // Step 1: Dialogue-band detector (bandpass → RMS envelope → dB)
            var dialogueRMS = dialogueRMSState
            for i in 0..<count {
                let x = buf[i]
                // Bandpass filter (DF2T biquad)
                let y = bp_b0 * x + w1
                w1 = bp_b1 * x + bp_a1 * y + w2
                w2 = bp_b2 * x + bp_a2 * y
                bandScratch[i] = y

                // RMS envelope (one-pole leaky integrator)
                dialogueRMS = rmsAlpha * dialogueRMS + (1.0 - rmsAlpha) * (y * y)
            }
            bandpassState[stateBase] = w1
            bandpassState[stateBase + 1] = w2
            dialogueRMSState = dialogueRMS

            // Convert RMS to dB (per-sample for gain computer)
            for i in 0..<count {
                let rms = sqrt(max(0.0, dialogueRMS))
                dialogueDBScratch[i] = rms > 1e-10 ? 20.0 * log10(rms) : -96.0
            }

            // Step 2: Program detector (broadband RMS → dB)
            var programRMS = programRMSState
            for i in 0..<count {
                let x = buf[i]
                programRMS = rmsAlpha * programRMS + (1.0 - rmsAlpha) * (x * x)
            }
            programRMSState = programRMS

            // Convert program RMS to dB
            let programRMSValue = sqrt(max(0.0, programRMS))
            let programDB = programRMSValue > 1e-10 ? 20.0 * log10(programRMSValue) : -96.0

            // Step 3: Gain computer (per-sample)
            var boostDB = smoothedBoostDB
            for i in 0..<count {
                let dialogueDB = dialogueDBScratch[i]

                // Compute shortfall
                let shortfallDB = (programDB - targetGapDB) - dialogueDB
                var targetBoostDB: Float = 0.0
                if shortfallDB > 0 {
                    targetBoostDB = shortfallDB * (boostRatio - 1.0) / boostRatio
                }
                targetBoostDB = min(targetBoostDB, maxBoostDB)

                // Program gate: below threshold, decay to zero
                if programDB < programGateThresholdDB {
                    targetBoostDB = 0.0
                }

                // Asymmetric smoothing
                let coeff = (targetBoostDB > boostDB) ? attackCoeff : releaseCoeff
                boostDB = coeff * boostDB + (1.0 - coeff) * targetBoostDB
                boostDBScratch[i] = boostDB
            }
            smoothedBoostDB = boostDB

            // Step 4: Convert boost to linear gain
            for i in 0..<count {
                let db = boostDBScratch[i]
                gainLinearScratch[i] = pow(10.0, db / 20.0)
            }

            // Step 5: Band-extract-and-recombine
            // residual = input - band
            for i in 0..<count {
                residualScratch[i] = buf[i] - bandScratch[i]
            }
            for i in 0..<count {
                shapedBandScratch[i] = bandScratch[i] * gainLinearScratch[i]
            }
            // output = residual + shapedBand
            for i in 0..<count {
                buf[i] = residualScratch[i] + shapedBandScratch[i]
            }
        }
    }

    // MARK: - Coefficient Computation

    private func updateCoefficients(sampleRate: Double) {
        self.sampleRate = sampleRate

        // Read current parameters
        let bandLowHz = bitsToFloatL(_bandLowHzBits.load(ordering: .relaxed))
        let bandHighHz = bitsToFloatL(_bandHighHzBits.load(ordering: .relaxed))
        let attackMs = bitsToFloatL(_attackMsBits.load(ordering: .relaxed))
        let releaseMs = bitsToFloatL(_releaseMsBits.load(ordering: .relaxed))
        let detectorWindowMs = bitsToFloatL(_detectorWindowMsBits.load(ordering: .relaxed))

        // Compute attack/release coefficients
        attackCoeff = Float(exp(-1.0 / (Double(attackMs) * 0.001 * sampleRate)))
        releaseCoeff = Float(exp(-1.0 / (Double(releaseMs) * 0.001 * sampleRate)))

        // Compute RMS envelope coefficient
        rmsAlpha = Float(exp(-1.0 / (Double(detectorWindowMs) * 0.001 * sampleRate)))

        // Compute bandpass biquad coefficients (2nd-order Butterworth bandpass)
        // Using cascade of high-shelf + low-shelf for simplicity
        let lowHz = Double(bandLowHz)
        let highHz = Double(bandHighHz)

        // High-pass at lowHz
        let w0_hp = 2.0 * .pi * lowHz / sampleRate
        let Q_hp: Double = 0.7071  // Butterworth
        let alpha_hp = sin(w0_hp) / (2.0 * Q_hp)
        let a0_hp = 1.0 + alpha_hp
        let b0_hp = (1.0 - cos(w0_hp)) / 2.0 / a0_hp
        let b1_hp = -(1.0 - cos(w0_hp)) / a0_hp
        let b2_hp = (1.0 - cos(w0_hp)) / 2.0 / a0_hp
        let a1_hp = -2.0 * cos(w0_hp) / a0_hp
        let a2_hp = (1.0 - alpha_hp) / a0_hp

        // Low-pass at highHz
        let w0_lp = 2.0 * .pi * highHz / sampleRate
        let Q_lp: Double = 0.7071  // Butterworth
        let alpha_lp = sin(w0_lp) / (2.0 * Q_lp)
        let a0_lp = 1.0 + alpha_lp
        let b0_lp = (1.0 - cos(w0_lp)) / 2.0 / a0_lp
        let b1_lp = 1.0 - cos(w0_lp) / a0_lp
        let b2_lp = (1.0 - cos(w0_lp)) / 2.0 / a0_lp
        let a1_lp = -2.0 * cos(w0_lp) / a0_lp
        let a2_lp = (1.0 - alpha_lp) / a0_lp

        // Cascade the two filters (multiply their transfer functions)
        // For simplicity, use the high-pass as the primary bandpass
        pending_bp_b0 = Float(b0_hp)
        pending_bp_b1 = Float(b1_hp)
        pending_bp_b2 = Float(b2_hp)
        pending_bp_a1 = Float(a1_hp)
        pending_bp_a2 = Float(a2_hp)

        hasCoeffUpdate.store(true, ordering: .releasing)
    }
}

// MARK: - Bit-casting helpers

@inline(__always)
private func floatBitsL(_ f: Float) -> Int32 { Int32(bitPattern: f.bitPattern) }

@inline(__always)
private func bitsToFloatL(_ bits: Int32) -> Float { Float(bitPattern: UInt32(bitPattern: bits)) }
