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
    private static let maxChannels = 16

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

    // Voice gate atomics
    private let _voiceGateEnabled: ManagedAtomic<Int32>
    private let _modCenterHzBits: ManagedAtomic<Int32>  // Float bits
    private let _modBandwidthHzBits: ManagedAtomic<Int32>  // Float bits
    private let _envelopeWindowMsBits: ManagedAtomic<Int32>  // Float bits
    private let _measurementWindowMsBits: ManagedAtomic<Int32>  // Float bits
    private let _confidenceFloorIndexBits: ManagedAtomic<Int32>  // Float bits
    private let _confidenceCeilingIndexBits: ManagedAtomic<Int32>  // Float bits
    private let _minConfidenceBits: ManagedAtomic<Int32>  // Float bits

    // MARK: - Audio-Thread State

    /// Dialogue bandpass biquad state per channel: [ch * 2 + stateVar] (w1, w2).
    nonisolated(unsafe) private var bandpassState: [Float]

    /// Dialogue-band RMS envelope state per channel (one-pole leaky integrator on squared signal).
    nonisolated(unsafe) private var dialogueRMSState: [Float]

    /// Program RMS envelope state per channel (one-pole leaky integrator on squared signal).
    nonisolated(unsafe) private var programRMSState: [Float]

    /// Smoothed boost in dB per channel (audio thread only). Starts at 0.
    nonisolated(unsafe) private var smoothedBoostDB: [Float]

    /// Current sample rate (updated by main thread before audio starts).
    nonisolated(unsafe) private var sampleRate: Double = 48000.0

    // Voice gate state
    /// Decimation counter per channel for control-rate processing.
    nonisolated(unsafe) private var decimationCounter: [Int]
    /// Decimation factor (samples per control update).
    nonisolated(unsafe) private var decimationFactor: Int = 48  // ~1 kHz at 48 kHz

    /// Fast envelope state per channel for voice gate (separate from main detector).
    nonisolated(unsafe) private var fastEnvelopeState: [Float]

    /// Modulation bandpass biquad state per channel (w1, w2).
    nonisolated(unsafe) private var modBiquadW1: [Float]
    nonisolated(unsafe) private var modBiquadW2: [Float]

    /// Modulation band energy accumulator per channel.
    nonisolated(unsafe) private var modEnergyAccumulator: [Float]
    /// Total energy accumulator per channel.
    nonisolated(unsafe) private var totalEnergyAccumulator: [Float]
    /// Energy accumulator count per channel.
    nonisolated(unsafe) private var energyAccumulatorCount: [Int]

    /// Current confidence value per channel (0-1).
    nonisolated(unsafe) private var currentConfidence: [Float]

    /// Modulation bandpass coefficients (b0, b1, b2, a1, a2).
    nonisolated(unsafe) private var mod_b0: Float = 0.0
    nonisolated(unsafe) private var mod_b1: Float = 0.0
    nonisolated(unsafe) private var mod_b2: Float = 0.0
    nonisolated(unsafe) private var mod_na1: Float = 0.0
    nonisolated(unsafe) private var mod_na2: Float = 0.0

    /// Fast envelope alpha coefficient.
    nonisolated(unsafe) private var fastEnvelopeAlpha: Float = 0.0

    /// Energy window alpha coefficient.
    nonisolated(unsafe) private var energyWindowAlpha: Float = 0.0

    /// Precomputed attack/release coefficients (updated when parameters change).
    nonisolated(unsafe) private var attackCoeff:  Float = 0.0
    nonisolated(unsafe) private var releaseCoeff: Float = 0.0
    nonisolated(unsafe) private var rmsAlpha:    Float = 0.0

    /// Bandpass biquad coefficients (b0, b1, b2, a1, a2).
    nonisolated(unsafe) private var bp_b0: Float = 1.0
    nonisolated(unsafe) private var bp_b1: Float = 0.0
    nonisolated(unsafe) private var bp_b2: Float = 0.0
    nonisolated(unsafe) private var bp_na1: Float = 0.0
    nonisolated(unsafe) private var bp_na2: Float = 0.0

    /// Pending coefficients for thread-safe updates.
    nonisolated(unsafe) private var pending_bp_b0: Float = 1.0
    nonisolated(unsafe) private var pending_bp_b1: Float = 0.0
    nonisolated(unsafe) private var pending_bp_b2: Float = 0.0
    nonisolated(unsafe) private var pending_bp_na1: Float = 0.0
    nonisolated(unsafe) private var pending_bp_na2: Float = 0.0

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

        // Voice gate atomics
        _voiceGateEnabled = ManagedAtomic(0)
        _modCenterHzBits = ManagedAtomic(floatBitsL(5.0))
        _modBandwidthHzBits = ManagedAtomic(floatBitsL(5.0))
        _envelopeWindowMsBits = ManagedAtomic(floatBitsL(15.0))
        _measurementWindowMsBits = ManagedAtomic(floatBitsL(700.0))
        _confidenceFloorIndexBits = ManagedAtomic(floatBitsL(0.15))
        _confidenceCeilingIndexBits = ManagedAtomic(floatBitsL(0.45))
        _minConfidenceBits = ManagedAtomic(floatBitsL(0.2))

        bandpassState = Array(repeating: 0.0, count: Self.maxChannels * 2)  // maxChannels × 2 state vars
        dialogueRMSState = Array(repeating: 0.0, count: Self.maxChannels)
        programRMSState = Array(repeating: 0.0, count: Self.maxChannels)
        smoothedBoostDB = Array(repeating: 0.0, count: Self.maxChannels)
        decimationCounter = Array(repeating: 0, count: Self.maxChannels)
        fastEnvelopeState = Array(repeating: 0.0, count: Self.maxChannels)
        modBiquadW1 = Array(repeating: 0.0, count: Self.maxChannels)
        modBiquadW2 = Array(repeating: 0.0, count: Self.maxChannels)
        modEnergyAccumulator = Array(repeating: 0.0, count: Self.maxChannels)
        totalEnergyAccumulator = Array(repeating: 0.0, count: Self.maxChannels)
        energyAccumulatorCount = Array(repeating: 0, count: Self.maxChannels)
        currentConfidence = Array(repeating: 1.0, count: Self.maxChannels)

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

    func setVoiceGateEnabled(_ v: Bool) { _voiceGateEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setModulationCenterHz(_ hz: Float) { _modCenterHzBits.store(floatBitsL(hz), ordering: .relaxed) }
    func setModulationBandwidthHz(_ hz: Float) { _modBandwidthHzBits.store(floatBitsL(hz), ordering: .relaxed) }
    func setEnvelopeWindowMs(_ ms: Float) { _envelopeWindowMsBits.store(floatBitsL(ms), ordering: .relaxed) }
    func setMeasurementWindowMs(_ ms: Float) { _measurementWindowMsBits.store(floatBitsL(ms), ordering: .relaxed) }
    func setConfidenceFloorIndex(_ idx: Float) { _confidenceFloorIndexBits.store(floatBitsL(idx), ordering: .relaxed) }
    func setConfidenceCeilingIndex(_ idx: Float) { _confidenceCeilingIndexBits.store(floatBitsL(idx), ordering: .relaxed) }
    func setMinConfidence(_ conf: Float) { _minConfidenceBits.store(floatBitsL(conf), ordering: .relaxed) }

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

        // Voice gate parameters
        setVoiceGateEnabled(config.voiceGate.isEnabled)
        setModulationCenterHz(config.voiceGate.modulationCenterHz)
        setModulationBandwidthHz(config.voiceGate.modulationBandwidthHz)
        setEnvelopeWindowMs(config.voiceGate.envelopeWindowMs)
        setMeasurementWindowMs(config.voiceGate.measurementWindowMs)
        setConfidenceFloorIndex(config.voiceGate.confidenceFloorIndex)
        setConfidenceCeilingIndex(config.voiceGate.confidenceCeilingIndex)
        setMinConfidence(config.voiceGate.minConfidence)

        // Recompute coefficients on main thread
        updateCoefficients(sampleRate: sampleRate)
    }

    func resetState(sampleRate: Double) {
        self.sampleRate = sampleRate
        for i in 0..<bandpassState.count { bandpassState[i] = 0 }
        for i in 0..<dialogueRMSState.count { dialogueRMSState[i] = 0.0 }
        for i in 0..<programRMSState.count { programRMSState[i] = 0.0 }
        for i in 0..<smoothedBoostDB.count { smoothedBoostDB[i] = 0.0 }

        // Reset voice gate state
        for i in 0..<decimationCounter.count { decimationCounter[i] = 0 }
        for i in 0..<fastEnvelopeState.count { fastEnvelopeState[i] = 0.0 }
        for i in 0..<modBiquadW1.count { modBiquadW1[i] = 0.0 }
        for i in 0..<modBiquadW2.count { modBiquadW2[i] = 0.0 }
        for i in 0..<modEnergyAccumulator.count { modEnergyAccumulator[i] = 0.0 }
        for i in 0..<totalEnergyAccumulator.count { totalEnergyAccumulator[i] = 0.0 }
        for i in 0..<energyAccumulatorCount.count { energyAccumulatorCount[i] = 0 }
        for i in 0..<currentConfidence.count { currentConfidence[i] = 1.0 }

        updateCoefficients(sampleRate: sampleRate)
    }

    // MARK: - Audio Thread: Process

    @inline(__always)
    func process(
        abl: UnsafeMutableAudioBufferListPointer,
        numCh: Int,
        count: Int
    ) {
        guard _enabled.load(ordering: .relaxed) != 0, count > 0, count <= Self.maxFrameCount else { return }

        // Apply pending coefficient update if available
        if hasCoeffUpdate.exchange(false, ordering: .acquiringAndReleasing) {
            bp_b0 = pending_bp_b0
            bp_b1 = pending_bp_b1
            bp_b2 = pending_bp_b2
            bp_na1 = pending_bp_na1
            bp_na2 = pending_bp_na2
        }

        // Read parameters (once per block)
        let targetGapDB = bitsToFloatL(_targetGapDBBits.load(ordering: .relaxed))
        let boostRatio = bitsToFloatL(_boostRatioBits.load(ordering: .relaxed))
        let maxBoostDB = bitsToFloatL(_maxBoostDBBits.load(ordering: .relaxed))
        let programGateThresholdDB = bitsToFloatL(_programGateThresholdDBBits.load(ordering: .relaxed))

        // Voice gate parameters
        let voiceGateOn = _voiceGateEnabled.load(ordering: .relaxed) != 0
        let confidenceFloorIdx = bitsToFloatL(_confidenceFloorIndexBits.load(ordering: .relaxed))
        let confidenceCeilingIdx = bitsToFloatL(_confidenceCeilingIndexBits.load(ordering: .relaxed))
        let minConf = bitsToFloatL(_minConfidenceBits.load(ordering: .relaxed))
        let measurementWindowMs = bitsToFloatL(_measurementWindowMsBits.load(ordering: .relaxed))

        // Process each channel
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stateBase = ch * 2
            var w1 = bandpassState[stateBase]
            var w2 = bandpassState[stateBase + 1]

            // Step 1: Dialogue-band detector (bandpass → RMS envelope → dB)
            var dialogueRMS = dialogueRMSState[ch]
            var fastEnv = fastEnvelopeState[ch]
            var modW1 = modBiquadW1[ch]
            var modW2 = modBiquadW2[ch]
            var decimCounter = decimationCounter[ch]

            for i in 0..<count {
                let x = buf[i]
                // Bandpass filter (DF2T biquad)
                let y = bp_b0 * x + w1
                w1 = bp_b1 * x + bp_na1 * y + w2
                w2 = bp_b2 * x + bp_na2 * y
                bandScratch[i] = y

                // RMS envelope (one-pole leaky integrator)
                dialogueRMS = rmsAlpha * dialogueRMS + (1.0 - rmsAlpha) * (y * y)

                // Voice gate: fast envelope detector (decimated)
                if voiceGateOn {
                    fastEnv = fastEnvelopeAlpha * fastEnv + (1.0 - fastEnvelopeAlpha) * abs(y)

                    decimCounter += 1
                    if decimCounter >= decimationFactor {
                        decimCounter = 0

                        // Modulation bandpass filter on envelope
                        let modY = mod_b0 * fastEnv + modW1
                        modW1 = mod_b1 * fastEnv + mod_na1 * modY + modW2
                        modW2 = mod_b2 * fastEnv + mod_na2 * modY

                        // Accumulate energy
                        modEnergyAccumulator[ch] += modY * modY
                        totalEnergyAccumulator[ch] += fastEnv * fastEnv
                        energyAccumulatorCount[ch] += 1

                        // Update confidence when we have enough samples
                        let measurementWindowSamples = Double(measurementWindowMs) * sampleRate / 1000.0 / Double(decimationFactor)
                        if energyAccumulatorCount[ch] >= Int(measurementWindowSamples) {
                            let modEnergy = modEnergyAccumulator[ch] / Float(energyAccumulatorCount[ch])
                            let totalEnergy = totalEnergyAccumulator[ch] / Float(energyAccumulatorCount[ch])
                            let epsilon: Float = 1e-10
                            let modulationIndex = modEnergy / (totalEnergy + epsilon)

                            // Compute confidence
                            var confidence = (modulationIndex - confidenceFloorIdx) / (confidenceCeilingIdx - confidenceFloorIdx)
                            confidence = max(0.0, min(1.0, confidence))
                            confidence = max(confidence, minConf)

                            currentConfidence[ch] = confidence

                            // Reset accumulators
                            modEnergyAccumulator[ch] = 0.0
                            totalEnergyAccumulator[ch] = 0.0
                            energyAccumulatorCount[ch] = 0
                        }
                    }
                }
            }
            bandpassState[stateBase] = w1
            bandpassState[stateBase + 1] = w2
            dialogueRMSState[ch] = dialogueRMS
            fastEnvelopeState[ch] = fastEnv
            modBiquadW1[ch] = modW1
            modBiquadW2[ch] = modW2
            decimationCounter[ch] = decimCounter

            // Convert RMS to dB (per-sample for gain computer)
            for i in 0..<count {
                let rms = sqrt(max(0.0, dialogueRMS))
                dialogueDBScratch[i] = rms > 1e-10 ? 20.0 * log10(rms) : -96.0
            }

            // Step 2: Program detector (broadband RMS → dB)
            var programRMS = programRMSState[ch]
            for i in 0..<count {
                let x = buf[i]
                programRMS = rmsAlpha * programRMS + (1.0 - rmsAlpha) * (x * x)
            }
            programRMSState[ch] = programRMS

            // Convert program RMS to dB
            let programRMSValue = sqrt(max(0.0, programRMS))
            let programDB = programRMSValue > 1e-10 ? 20.0 * log10(programRMSValue) : -96.0

            // Step 3: Gain computer (per-sample)
            var boostDB = smoothedBoostDB[ch]
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

                // Voice gate: scale by confidence if enabled
                if voiceGateOn {
                    targetBoostDB *= currentConfidence[ch]
                }

                // Asymmetric smoothing
                let coeff = (targetBoostDB > boostDB) ? attackCoeff : releaseCoeff
                boostDB = coeff * boostDB + (1.0 - coeff) * targetBoostDB
                boostDBScratch[i] = boostDB
            }
            smoothedBoostDB[ch] = boostDB

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

    /// RBJ "constant skirt gain, peak gain = Q" bandpass biquad. Shared by the dialogue-band
    /// filter and the voice-gate modulation filter — one correct implementation instead of two.
    /// Coefficients follow this codebase's Direct Form II Transposed convention: na1/na2 are
    /// pre-negated (-a1/a0, -a2/a0) for use in the +form recursion.
    private func computeBandpassCoefficients(centerHz: Double, q: Double, sampleRate: Double) -> (b0: Float, b1: Float, b2: Float, na1: Float, na2: Float) {
        let w0 = 2.0 * .pi * centerHz / sampleRate
        let alpha = sin(w0) / (2.0 * max(q, 0.05))   // guard against a degenerate q
        let a0 = 1.0 + alpha
        return (
            b0:  Float(alpha / a0),
            b1:  Float(0.0),
            b2:  Float(-alpha / a0),
            na1: Float(2.0 * cos(w0) / a0),        // = -a1/a0, pre-negated per this codebase's DF2T convention
            na2: Float(-(1.0 - alpha) / a0)         // = -a2/a0, pre-negated per this codebase's DF2T convention
        )
    }

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

        // Compute dialogue-band bandpass coefficients (true bandpass, not cascade)
        let centerHz = sqrt(Double(bandLowHz) * Double(bandHighHz))   // geometric mean
        let bandwidthHz = max(1.0, Double(bandHighHz - bandLowHz))     // guard bandHighHz > bandLowHz
        let q = centerHz / bandwidthHz
        let coeffs = computeBandpassCoefficients(centerHz: centerHz, q: q, sampleRate: sampleRate)
        pending_bp_b0 = coeffs.b0
        pending_bp_b1 = coeffs.b1
        pending_bp_b2 = coeffs.b2
        pending_bp_na1 = coeffs.na1
        pending_bp_na2 = coeffs.na2

        // Voice gate coefficients
        let modCenterHz = bitsToFloatL(_modCenterHzBits.load(ordering: .relaxed))
        let modBandwidthHz = bitsToFloatL(_modBandwidthHzBits.load(ordering: .relaxed))
        let envelopeWindowMs = bitsToFloatL(_envelopeWindowMsBits.load(ordering: .relaxed))
        let measurementWindowMs = bitsToFloatL(_measurementWindowMsBits.load(ordering: .relaxed))

        // Compute decimation factor for ~1 kHz control rate
        let controlRateHz: Double = 1000.0
        decimationFactor = max(1, Int(sampleRate / controlRateHz))

        // Compute fast envelope alpha
        fastEnvelopeAlpha = Float(exp(-1.0 / (Double(envelopeWindowMs) * 0.001 * sampleRate)))

        // Compute modulation bandpass at control rate (not audio rate)
        let controlSampleRate = sampleRate / Double(decimationFactor)
        let q_mod = Double(modCenterHz) / Double(modBandwidthHz)   // Hz / Hz, correct
        let modCoeffs = computeBandpassCoefficients(centerHz: Double(modCenterHz), q: q_mod, sampleRate: controlSampleRate)
        mod_b0 = modCoeffs.b0
        mod_b1 = modCoeffs.b1
        mod_b2 = modCoeffs.b2
        mod_na1 = modCoeffs.na1
        mod_na2 = modCoeffs.na2

        hasCoeffUpdate.store(true, ordering: .releasing)
    }
}

// MARK: - Bit-casting helpers

@inline(__always)
private func floatBitsL(_ f: Float) -> Int32 { Int32(bitPattern: f.bitPattern) }

@inline(__always)
private func bitsToFloatL(_ bits: Int32) -> Float { Float(bitPattern: UInt32(bitPattern: bits)) }
