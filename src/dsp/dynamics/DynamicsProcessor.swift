import Atomics
import AudioToolbox
import CoreAudio
import Foundation

/// Real-time dynamics processor.
///
/// Signal chain (per buffer):
/// ```
/// Input → [De-Esser] → [Multiband Compressor] → [Compressor] → [Expander]
///       → [Soft Clipper] → [Look-Ahead Ring Buffer] → [Brickwall Limiter] → Output
/// ```
///
/// Thread safety: atomic parameters are written by the main thread and read by the audio
/// thread. All filter/envelope state is accessed exclusively from the audio thread and is
/// marked `nonisolated(unsafe)`.
final class DynamicsProcessor: @unchecked Sendable {

    // MARK: - Constants

    static let maxLookAheadSamples: Int = 4096

    // MARK: - Audio-Thread State

    private let channelCount: Int

    /// Current sample rate. Written by the main thread before audio starts (or on
    /// quiescent reconfigure). Read only on the audio thread during processing.
    nonisolated(unsafe) var storedSampleRate: Double

    // ── Look-ahead (limiter) ──────────────────────────────────────────────
    private let lookAheadBufs: [UnsafeMutablePointer<Float>]
    nonisolated(unsafe) var lookAheadSize: Int
    nonisolated(unsafe) var lookAheadWriteIndex: Int = 0
    nonisolated(unsafe) var limiterGainCurrent: Float = 1.0

    // ── De-esser ─────────────────────────────────────────────────────────
    /// Biquad state per channel: [ch * 2 + stateVar] (w1, w2).
    nonisolated(unsafe) var deEsserFilterState: [Float]
    /// Smoothed gain-reduction dB (≤ 0). Audio thread only.
    nonisolated(unsafe) var deEsserEnvDB: Float = 0.0

    // ── Multiband compressor ──────────────────────────────────────────────
    /// LR4 biquad states: 4 chains × 2 stages × 2 state vars = 16 floats per channel.
    /// Layout: ch*16 + chainIdx*4 + stageIdx*2 + stateVar
    nonisolated(unsafe) var mbFilterState: [Float]
    /// Smoothed linear gains per band (audio thread only). Start at unity.
    nonisolated(unsafe) var mbGainLow: Float  = 1.0
    nonisolated(unsafe) var mbGainMid: Float  = 1.0
    nonisolated(unsafe) var mbGainHigh: Float = 1.0
    /// Pre-allocated per-band temp buffers [bandIdx 0-2][chIdx].
    private let mbBandBufs: [[UnsafeMutablePointer<Float>]]

    // ── Compressor ────────────────────────────────────────────────────────
    /// Smoothed gain-reduction dB (≤ 0). Audio thread only.
    nonisolated(unsafe) var compEnvDB: Float = 0.0

    // ── Expander ──────────────────────────────────────────────────────────
    /// Smoothed gain-reduction dB (≤ 0). Audio thread only.
    nonisolated(unsafe) var expEnvDB: Float = 0.0
    /// Fixed time-constant alphas for expander (5 ms attack, 200 ms release).
    nonisolated(unsafe) var expanderAlphaAttack:  Float = 0.0
    nonisolated(unsafe) var expanderAlphaRelease: Float = 0.0

    // MARK: - Atomic Parameters (main thread → audio thread)

    // De-esser
    private let _deEsserEnabled:    ManagedAtomic<Int32>
    private let _deEsserFreqBits:   ManagedAtomic<Int32>   // Hz as Float bits
    private let _deEsserThreshBits: ManagedAtomic<Int32>   // dB as Float bits

    // Multiband compressor
    private let _mbEnabled:        ManagedAtomic<Int32>
    private let _mbCrossLMBits:    ManagedAtomic<Int32>    // crossLowMid Hz
    private let _mbCrossMHBits:    ManagedAtomic<Int32>    // crossMidHigh Hz
    private let _mbThreshLowBits:  ManagedAtomic<Int32>    // dB
    private let _mbThreshMidBits:  ManagedAtomic<Int32>    // dB
    private let _mbThreshHighBits: ManagedAtomic<Int32>    // dB

    // Compressor
    private let _compEnabled:      ManagedAtomic<Int32>
    private let _compThreshBits:   ManagedAtomic<Int32>    // dB
    private let _compRatioBits:    ManagedAtomic<Int32>    // ratio
    private let _compAlphaAttack:  ManagedAtomic<Int32>    // precomputed alpha
    private let _compAlphaRelease: ManagedAtomic<Int32>    // precomputed alpha
    private let _compMakeupBits:   ManagedAtomic<Int32>    // linear gain

    // Expander
    private let _expEnabled:    ManagedAtomic<Int32>
    private let _expThreshBits: ManagedAtomic<Int32>       // dB
    private let _expRatioBits:  ManagedAtomic<Int32>       // expansion factor
    private let _expRangeDBBits: ManagedAtomic<Int32>      // dB ceiling (negative)

    // Soft clipper
    private let _softClipperEnabled:   ManagedAtomic<Int32>
    private let _softClipperDrive:     ManagedAtomic<Int32>
    private let _softClipperThreshold: ManagedAtomic<Int32>
    private let _softClipperKnee:      ManagedAtomic<Int32>

    // Brickwall limiter
    private let _limiterEnabled:      ManagedAtomic<Int32>
    private let _limiterCeiling:      ManagedAtomic<Int32>
    private let _limiterAlphaAttack:  ManagedAtomic<Int32>
    private let _limiterAlphaRelease: ManagedAtomic<Int32>

    // MARK: - Gain Reduction Reporting (audio thread → main thread)

    private let _gainReductionBits: ManagedAtomic<Int32>
    private let _clipperActiveBits: ManagedAtomic<Int32>

    var gainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _gainReductionBits.load(ordering: .relaxed)))
    }
    var clipperEngaged: Bool {
        _clipperActiveBits.load(ordering: .relaxed) != 0
    }

    // MARK: - Initialization

    init(channelCount: UInt32, sampleRate: Double) {
        let ch = Int(channelCount)
        self.channelCount    = ch
        self.storedSampleRate = sampleRate

        // Look-ahead ring buffers
        var labufs: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<ch {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLookAheadSamples)
            p.initialize(repeating: 0, count: Self.maxLookAheadSamples)
            labufs.append(p)
        }
        self.lookAheadBufs = labufs
        self.lookAheadSize = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: 2.0)

        // De-esser: 2 state vars per channel
        self.deEsserFilterState = Array(repeating: 0.0, count: ch * 2)

        // Multiband: 16 state vars per channel
        self.mbFilterState = Array(repeating: 0.0, count: ch * 16)

        // Multiband temp band buffers: [3 bands][channelCount]
        var bandBufs: [[UnsafeMutablePointer<Float>]] = []
        for _ in 0..<3 {
            var chBufs: [UnsafeMutablePointer<Float>] = []
            for _ in 0..<ch {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLookAheadSamples)
                p.initialize(repeating: 0, count: Self.maxLookAheadSamples)
                chBufs.append(p)
            }
            bandBufs.append(chBufs)
        }
        self.mbBandBufs = bandBufs

        // Expander fixed alphas
        self.expanderAlphaAttack  = Self.computeAlpha(tauSeconds: 0.005, sampleRate: sampleRate)
        self.expanderAlphaRelease = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sampleRate)

        // Precomputed compressor alphas from default settings
        let compAlphaAtt = Self.computeAlpha(tauSeconds: 0.025, sampleRate: sampleRate)
        let compAlphaRel = Self.computeAlpha(tauSeconds: 0.150, sampleRate: sampleRate)

        // Limiter defaults
        let defCeiling   = Self.dbToLinear(-0.2)
        let limAlphaAtt  = Self.computeAlpha(tauSeconds: 0.0001, sampleRate: sampleRate)
        let limAlphaRel  = Self.computeAlpha(tauSeconds: 0.020,  sampleRate: sampleRate)

        // Atomics — de-esser
        _deEsserEnabled    = ManagedAtomic(0)
        _deEsserFreqBits   = ManagedAtomic(floatBits(6000.0))
        _deEsserThreshBits = ManagedAtomic(floatBits(-20.0))

        // Atomics — multiband
        _mbEnabled        = ManagedAtomic(0)
        _mbCrossLMBits    = ManagedAtomic(floatBits(150.0))
        _mbCrossMHBits    = ManagedAtomic(floatBits(3000.0))
        _mbThreshLowBits  = ManagedAtomic(floatBits(0.0))
        _mbThreshMidBits  = ManagedAtomic(floatBits(0.0))
        _mbThreshHighBits = ManagedAtomic(floatBits(0.0))

        // Atomics — compressor
        _compEnabled      = ManagedAtomic(0)
        _compThreshBits   = ManagedAtomic(floatBits(-16.0))
        _compRatioBits    = ManagedAtomic(floatBits(3.5))
        _compAlphaAttack  = ManagedAtomic(floatBits(compAlphaAtt))
        _compAlphaRelease = ManagedAtomic(floatBits(compAlphaRel))
        _compMakeupBits   = ManagedAtomic(floatBits(Self.dbToLinear(2.5)))

        // Atomics — expander
        _expEnabled     = ManagedAtomic(0)
        _expThreshBits  = ManagedAtomic(floatBits(-35.0))
        _expRatioBits   = ManagedAtomic(floatBits(1.5))
        _expRangeDBBits = ManagedAtomic(floatBits(-12.0))

        // Atomics — soft clipper
        _softClipperEnabled   = ManagedAtomic(0)
        _softClipperDrive     = ManagedAtomic(floatBits(Self.dbToLinear(0.0)))
        _softClipperThreshold = ManagedAtomic(floatBits(Self.dbToLinear(-1.5)))
        _softClipperKnee      = ManagedAtomic(floatBits(0.5))

        // Atomics — limiter
        _limiterEnabled      = ManagedAtomic(1)
        _limiterCeiling      = ManagedAtomic(floatBits(defCeiling))
        _limiterAlphaAttack  = ManagedAtomic(floatBits(limAlphaAtt))
        _limiterAlphaRelease = ManagedAtomic(floatBits(limAlphaRel))

        // Reporting
        _gainReductionBits = ManagedAtomic(floatBits(0.0))
        _clipperActiveBits = ManagedAtomic(0)
    }

    deinit {
        for p in lookAheadBufs {
            p.deinitialize(count: Self.maxLookAheadSamples)
            p.deallocate()
        }
        for band in mbBandBufs {
            for p in band {
                p.deinitialize(count: Self.maxLookAheadSamples)
                p.deallocate()
            }
        }
    }

    // MARK: - Parameter Update API (main thread)

    func setDeEsserEnabled(_ v: Bool)        { _deEsserEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setDeEsserFrequencyHz(_ hz: Float)  { _deEsserFreqBits.store(floatBits(max(20.0, hz)), ordering: .relaxed) }
    func setDeEsserThresholdDB(_ db: Float)  { _deEsserThreshBits.store(floatBits(db), ordering: .relaxed) }

    func setMBEnabled(_ v: Bool)             { _mbEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setMBCrossLowMidHz(_ hz: Float)     { _mbCrossLMBits.store(floatBits(max(20.0, hz)), ordering: .relaxed) }
    func setMBCrossMidHighHz(_ hz: Float)    { _mbCrossMHBits.store(floatBits(max(20.0, hz)), ordering: .relaxed) }
    func setMBThresholdLowDB(_ db: Float)    { _mbThreshLowBits.store(floatBits(db),  ordering: .relaxed) }
    func setMBThresholdMidDB(_ db: Float)    { _mbThreshMidBits.store(floatBits(db),  ordering: .relaxed) }
    func setMBThresholdHighDB(_ db: Float)   { _mbThreshHighBits.store(floatBits(db), ordering: .relaxed) }

    func setCompressorEnabled(_ v: Bool)     { _compEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setCompressorThresholdDB(_ db: Float) { _compThreshBits.store(floatBits(db), ordering: .relaxed) }
    func setCompressorRatio(_ r: Float)      { _compRatioBits.store(floatBits(max(1.0, r)), ordering: .relaxed) }
    func setCompressorAttackMs(_ ms: Float, sampleRate: Double) {
        let tau = Double(max(ms, 0.1)) / 1000.0
        _compAlphaAttack.store(floatBits(Self.computeAlpha(tauSeconds: Float(tau), sampleRate: sampleRate)), ordering: .relaxed)
    }
    func setCompressorReleaseMs(_ ms: Float, sampleRate: Double) {
        let tau = Double(max(ms, 5.0)) / 1000.0
        _compAlphaRelease.store(floatBits(Self.computeAlpha(tauSeconds: Float(tau), sampleRate: sampleRate)), ordering: .relaxed)
    }
    func setCompressorMakeupGainDB(_ db: Float) {
        _compMakeupBits.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }

    func setExpanderEnabled(_ v: Bool)       { _expEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setExpanderThresholdDB(_ db: Float) { _expThreshBits.store(floatBits(db), ordering: .relaxed) }
    func setExpanderRatio(_ r: Float)        { _expRatioBits.store(floatBits(max(1.0, r)), ordering: .relaxed) }
    func setExpanderRangeDB(_ db: Float)     { _expRangeDBBits.store(floatBits(min(0.0, db)), ordering: .relaxed) }

    func setSoftClipperEnabled(_ enabled: Bool) { _softClipperEnabled.store(enabled ? 1 : 0, ordering: .relaxed) }
    func setSoftClipperDriveDB(_ db: Float) {
        _softClipperDrive.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }
    func setSoftClipperThresholdDB(_ db: Float) {
        _softClipperThreshold.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }
    func setSoftClipperKnee(_ knee: Float) {
        _softClipperKnee.store(floatBits(max(0.001, min(1.0, knee))), ordering: .relaxed)
    }

    func setLimiterEnabled(_ enabled: Bool) { _limiterEnabled.store(enabled ? 1 : 0, ordering: .relaxed) }
    func setLimiterCeilingDB(_ db: Float) {
        _limiterCeiling.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }
    func setLimiterAttackMs(_ ms: Float, sampleRate: Double) {
        let tau = max(ms, 0.0) / 1000.0
        let alpha: Float = tau < 1e-7 ? 0.0 : Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)
        _limiterAlphaAttack.store(floatBits(alpha), ordering: .relaxed)
    }
    func setLimiterReleaseMs(_ ms: Float, sampleRate: Double) {
        let tau = ms / 1000.0
        _limiterAlphaRelease.store(floatBits(Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)), ordering: .relaxed)
    }
    func setLimiterLookAheadMs(_ ms: Float, sampleRate: Double) {
        let newSize = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: ms)
        guard newSize != lookAheadSize else { return }
        for p in lookAheadBufs { p.initialize(repeating: 0, count: Self.maxLookAheadSamples) }
        lookAheadWriteIndex = 0
        limiterGainCurrent  = 1.0
        lookAheadSize = newSize
    }

    /// Applies a full config snapshot atomically (main thread).
    func applyConfig(_ config: DynamicsConfig, sampleRate: Double) {
        storedSampleRate = sampleRate

        setDeEsserEnabled(config.deEsser.isEnabled)
        setDeEsserFrequencyHz(config.deEsser.frequencyHz)
        setDeEsserThresholdDB(config.deEsser.thresholdDB)

        setMBEnabled(config.multibandCompressor.isEnabled)
        setMBCrossLowMidHz(config.multibandCompressor.crossLowMidHz)
        setMBCrossMidHighHz(config.multibandCompressor.crossMidHighHz)
        setMBThresholdLowDB(config.multibandCompressor.thresholdLowDB)
        setMBThresholdMidDB(config.multibandCompressor.thresholdMidDB)
        setMBThresholdHighDB(config.multibandCompressor.thresholdHighDB)

        setCompressorEnabled(config.compressor.isEnabled)
        setCompressorThresholdDB(config.compressor.thresholdDB)
        setCompressorRatio(config.compressor.ratio)
        setCompressorAttackMs(config.compressor.attackMs, sampleRate: sampleRate)
        setCompressorReleaseMs(config.compressor.releaseMs, sampleRate: sampleRate)
        setCompressorMakeupGainDB(config.compressor.makeupGainDB)

        setExpanderEnabled(config.expander.isEnabled)
        setExpanderThresholdDB(config.expander.thresholdDB)
        setExpanderRatio(config.expander.ratio)
        setExpanderRangeDB(config.expander.rangeDB)
        expanderAlphaAttack  = Self.computeAlpha(tauSeconds: 0.005, sampleRate: sampleRate)
        expanderAlphaRelease = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sampleRate)

        setSoftClipperEnabled(config.softClipper.isEnabled)
        setSoftClipperDriveDB(config.softClipper.driveDB)
        setSoftClipperThresholdDB(config.softClipper.thresholdDB)
        setSoftClipperKnee(config.softClipper.kneeSmooth)

        setLimiterEnabled(config.limiter.isEnabled)
        setLimiterCeilingDB(config.limiter.ceilingDB)
        setLimiterAttackMs(config.limiter.attackMs, sampleRate: sampleRate)
        setLimiterReleaseMs(config.limiter.releaseMs, sampleRate: sampleRate)
        setLimiterLookAheadMs(config.limiter.lookAheadMs, sampleRate: sampleRate)
    }

    /// Called when the pipeline sample rate changes (main thread).
    func updateSampleRate(_ sampleRate: Double, attackMs: Float, releaseMs: Float, lookAheadMs: Float) {
        storedSampleRate = sampleRate
        for p in lookAheadBufs { p.initialize(repeating: 0, count: Self.maxLookAheadSamples) }
        lookAheadWriteIndex = 0
        lookAheadSize       = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: lookAheadMs)
        limiterGainCurrent  = 1.0
        for i in 0..<deEsserFilterState.count { deEsserFilterState[i] = 0 }
        for i in 0..<mbFilterState.count       { mbFilterState[i] = 0 }
        compEnvDB   = 0.0
        expEnvDB    = 0.0
        deEsserEnvDB = 0.0
        mbGainLow   = 1.0
        mbGainMid   = 1.0
        mbGainHigh  = 1.0
        expanderAlphaAttack  = Self.computeAlpha(tauSeconds: 0.005, sampleRate: sampleRate)
        expanderAlphaRelease = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sampleRate)
        setLimiterAttackMs(attackMs, sampleRate: sampleRate)
        setLimiterReleaseMs(releaseMs, sampleRate: sampleRate)
    }

    // MARK: - DSP Processing (audio thread)

    @inline(__always)
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let count = Int(frameCount)
        guard count > 0 else { return }
        let abl   = UnsafeMutableAudioBufferListPointer(bufferList)
        let numCh = min(channelCount, abl.count)
        guard numCh > 0 else { return }

        let deEsserOn = _deEsserEnabled.load(ordering: .relaxed) != 0
        let mbOn      = _mbEnabled.load(ordering: .relaxed) != 0
        let compOn    = _compEnabled.load(ordering: .relaxed) != 0
        let expOn     = _expEnabled.load(ordering: .relaxed) != 0
        let softOn    = _softClipperEnabled.load(ordering: .relaxed) != 0
        let limOn     = _limiterEnabled.load(ordering: .relaxed) != 0

        guard deEsserOn || mbOn || compOn || expOn || softOn || limOn else {
            _gainReductionBits.store(floatBits(0.0), ordering: .relaxed)
            return
        }

        if deEsserOn { processDeEsser(abl: abl, numCh: numCh, count: count) }
        if mbOn      { processMultiband(abl: abl, numCh: numCh, count: count) }
        if compOn    { processCompressor(abl: abl, numCh: numCh, count: count) }
        if expOn     { processExpander(abl: abl, numCh: numCh, count: count) }
        processSoftClipperAndLimiter(abl: abl, numCh: numCh, count: count, softOn: softOn, limOn: limOn)
    }

    // MARK: - Module 1: De-Esser

    @inline(__always)
    private func processDeEsser(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let sr       = storedSampleRate
        let freqHz   = bitsToFloat(_deEsserFreqBits.load(ordering: .relaxed))
        let thresh   = bitsToFloat(_deEsserThreshBits.load(ordering: .relaxed))
        // Fixed attack 1 ms, release 50 ms
        let alphaAtt = Self.computeAlpha(tauSeconds: 0.001, sampleRate: sr)
        let alphaRel = Self.computeAlpha(tauSeconds: 0.050, sampleRate: sr)
        let (b0, b1, b2, na1, na2) = Self.bpfCoeffs(fc: freqHz, q: 2.0, sr: sr)
        var env = deEsserEnvDB

        for frame in 0..<count {
            var sidePeak: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var w1 = deEsserFilterState[ch * 2]
                var w2 = deEsserFilterState[ch * 2 + 1]
                let y = Self.processBiquad(buf[frame], b0: b0, b1: b1, b2: b2, na1: na1, na2: na2, w1: &w1, w2: &w2)
                deEsserFilterState[ch * 2]     = w1
                deEsserFilterState[ch * 2 + 1] = w2
                let absY = y < 0 ? -y : y
                if absY > sidePeak { sidePeak = absY }
            }
            let sideDB: Float = sidePeak > 1e-5 ? 20.0 * log10(sidePeak) : -100.0
            let target: Float = sideDB > thresh ? thresh - sideDB : 0.0
            env = target < env
                ? alphaAtt * env + (1.0 - alphaAtt) * target
                : alphaRel * env + (1.0 - alphaRel) * target
            let gain = pow(10.0, env * 0.05)   // 10^(env/20)
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buf[frame] *= gain
            }
        }
        deEsserEnvDB = env
    }

    // MARK: - Module 2: Multiband Compressor

    @inline(__always)
    private func processMultiband(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let sr      = storedSampleRate
        let crossLM = bitsToFloat(_mbCrossLMBits.load(ordering: .relaxed))
        let crossMH = bitsToFloat(_mbCrossMHBits.load(ordering: .relaxed))
        let threshL = bitsToFloat(_mbThreshLowBits.load(ordering: .relaxed))
        let threshM = bitsToFloat(_mbThreshMidBits.load(ordering: .relaxed))
        let threshH = bitsToFloat(_mbThreshHighBits.load(ordering: .relaxed))

        // Fixed per-band time constants from spec
        let aAttL = Self.computeAlpha(tauSeconds: 0.040, sampleRate: sr)
        let aRelL = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sr)
        let aAttM = Self.computeAlpha(tauSeconds: 0.020, sampleRate: sr)
        let aRelM = Self.computeAlpha(tauSeconds: 0.100, sampleRate: sr)
        let aAttH = Self.computeAlpha(tauSeconds: 0.010, sampleRate: sr)
        let aRelH = Self.computeAlpha(tauSeconds: 0.050, sampleRate: sr)

        let (lpLMb0, lpLMb1, lpLMb2, lpLMa1, lpLMa2) = Self.lpfCoeffs(fc: crossLM, sr: sr)
        let (hpLMb0, hpLMb1, hpLMb2, hpLMa1, hpLMa2) = Self.hpfCoeffs(fc: crossLM, sr: sr)
        let (lpMHb0, lpMHb1, lpMHb2, lpMHa1, lpMHa2) = Self.lpfCoeffs(fc: crossMH, sr: sr)
        let (hpMHb0, hpMHb1, hpMHb2, hpMHa1, hpMHa2) = Self.hpfCoeffs(fc: crossMH, sr: sr)

        let safeCount = min(count, Self.maxLookAheadSamples)

        // Split into three band buffers and apply LR4 crossover filters per channel
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let b0 = mbBandBufs[0][ch]
            let b1 = mbBandBufs[1][ch]
            let b2 = mbBandBufs[2][ch]
            memcpy(b0, buf, safeCount * MemoryLayout<Float>.size)
            memcpy(b1, buf, safeCount * MemoryLayout<Float>.size)
            memcpy(b2, buf, safeCount * MemoryLayout<Float>.size)

            let base = ch * 16

            // Band 0: LP4 @ crossLM (chain 0 — stages 0 & 1)
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 0], s0w2 = mbFilterState[base + 1]
                let y0 = Self.processBiquad(b0[i], b0: lpLMb0, b1: lpLMb1, b2: lpLMb2, na1: lpLMa1, na2: lpLMa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 0] = s0w1; mbFilterState[base + 1] = s0w2
                var s1w1 = mbFilterState[base + 2], s1w2 = mbFilterState[base + 3]
                let y1 = Self.processBiquad(y0,    b0: lpLMb0, b1: lpLMb1, b2: lpLMb2, na1: lpLMa1, na2: lpLMa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 2] = s1w1; mbFilterState[base + 3] = s1w2
                b0[i] = y1
            }

            // Band 1a: HP4 @ crossLM (chain 1 — stages 0 & 1)
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 4], s0w2 = mbFilterState[base + 5]
                let y0 = Self.processBiquad(b1[i], b0: hpLMb0, b1: hpLMb1, b2: hpLMb2, na1: hpLMa1, na2: hpLMa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 4] = s0w1; mbFilterState[base + 5] = s0w2
                var s1w1 = mbFilterState[base + 6], s1w2 = mbFilterState[base + 7]
                let y1 = Self.processBiquad(y0,    b0: hpLMb0, b1: hpLMb1, b2: hpLMb2, na1: hpLMa1, na2: hpLMa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 6] = s1w1; mbFilterState[base + 7] = s1w2
                b1[i] = y1
            }

            // Band 1b: LP4 @ crossMH (chain 2 — stages 0 & 1)
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 8],  s0w2 = mbFilterState[base + 9]
                let y0 = Self.processBiquad(b1[i], b0: lpMHb0, b1: lpMHb1, b2: lpMHb2, na1: lpMHa1, na2: lpMHa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 8] = s0w1; mbFilterState[base + 9] = s0w2
                var s1w1 = mbFilterState[base + 10], s1w2 = mbFilterState[base + 11]
                let y1 = Self.processBiquad(y0,    b0: lpMHb0, b1: lpMHb1, b2: lpMHb2, na1: lpMHa1, na2: lpMHa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 10] = s1w1; mbFilterState[base + 11] = s1w2
                b1[i] = y1
            }

            // Band 2: HP4 @ crossMH (chain 3 — stages 0 & 1)
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 12], s0w2 = mbFilterState[base + 13]
                let y0 = Self.processBiquad(b2[i], b0: hpMHb0, b1: hpMHb1, b2: hpMHb2, na1: hpMHa1, na2: hpMHa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 12] = s0w1; mbFilterState[base + 13] = s0w2
                var s1w1 = mbFilterState[base + 14], s1w2 = mbFilterState[base + 15]
                let y1 = Self.processBiquad(y0,    b0: hpMHb0, b1: hpMHb1, b2: hpMHb2, na1: hpMHa1, na2: hpMHa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 14] = s1w1; mbFilterState[base + 15] = s1w2
                b2[i] = y1
            }
        }

        // Per-frame: detect band peaks, compute smoothed gain per band, sum bands back
        var gL = mbGainLow; var gM = mbGainMid; var gH = mbGainHigh

        for frame in 0..<safeCount {
            var pkL: Float = 0.0; var pkM: Float = 0.0; var pkH: Float = 0.0
            for ch in 0..<numCh {
                let vL = mbBandBufs[0][ch][frame]; let aL = vL < 0 ? -vL : vL; if aL > pkL { pkL = aL }
                let vM = mbBandBufs[1][ch][frame]; let aM = vM < 0 ? -vM : vM; if aM > pkM { pkM = aM }
                let vH = mbBandBufs[2][ch][frame]; let aH = vH < 0 ? -vH : vH; if aH > pkH { pkH = aH }
            }
            gL = mbSmoothedGain(peak: pkL, threshDB: threshL, gain: gL, alphaAtt: aAttL, alphaRel: aRelL)
            gM = mbSmoothedGain(peak: pkM, threshDB: threshM, gain: gM, alphaAtt: aAttM, alphaRel: aRelM)
            gH = mbSmoothedGain(peak: pkH, threshDB: threshH, gain: gH, alphaAtt: aAttH, alphaRel: aRelH)
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buf[frame] = mbBandBufs[0][ch][frame] * gL
                           + mbBandBufs[1][ch][frame] * gM
                           + mbBandBufs[2][ch][frame] * gH
            }
        }
        mbGainLow = gL; mbGainMid = gM; mbGainHigh = gH
    }

    /// Computes next smoothed linear gain for a single multiband compressor band.
    /// Fixed ratio of 4.0 as specified.
    @inline(__always)
    private func mbSmoothedGain(
        peak: Float, threshDB: Float, gain: Float,
        alphaAtt: Float, alphaRel: Float
    ) -> Float {
        let xDB: Float    = peak > 1e-5 ? 20.0 * log10(peak) : -100.0
        let deltaDB: Float = xDB > threshDB ? (threshDB + (xDB - threshDB) / 4.0) - xDB : 0.0
        let targetGain     = pow(10.0, deltaDB * 0.05)
        return targetGain < gain
            ? alphaAtt * gain + (1.0 - alphaAtt) * targetGain
            : alphaRel * gain + (1.0 - alphaRel) * targetGain
    }

    // MARK: - Module 3: Compressor

    @inline(__always)
    private func processCompressor(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let thresh   = bitsToFloat(_compThreshBits.load(ordering: .relaxed))
        let ratio    = bitsToFloat(_compRatioBits.load(ordering: .relaxed))
        let alphaAtt = bitsToFloat(_compAlphaAttack.load(ordering: .relaxed))
        let alphaRel = bitsToFloat(_compAlphaRelease.load(ordering: .relaxed))
        let makeup   = bitsToFloat(_compMakeupBits.load(ordering: .relaxed))
        var env = compEnvDB

        for frame in 0..<count {
            var peak: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let v = buf[frame]; let a = v < 0 ? -v : v; if a > peak { peak = a }
            }
            let xDB: Float    = peak > 1e-5 ? 20.0 * log10(peak) : -100.0
            let target: Float = xDB > thresh ? (thresh + (xDB - thresh) / ratio) - xDB : 0.0
            env = target < env
                ? alphaAtt * env + (1.0 - alphaAtt) * target
                : alphaRel * env + (1.0 - alphaRel) * target
            let gain = pow(10.0, env * 0.05) * makeup
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buf[frame] *= gain
            }
        }
        compEnvDB = env
    }

    // MARK: - Module 4: Expander

    @inline(__always)
    private func processExpander(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let thresh   = bitsToFloat(_expThreshBits.load(ordering: .relaxed))
        let ratio    = bitsToFloat(_expRatioBits.load(ordering: .relaxed))
        let rangeDB  = bitsToFloat(_expRangeDBBits.load(ordering: .relaxed))
        let alphaAtt = expanderAlphaAttack
        let alphaRel = expanderAlphaRelease
        var env = expEnvDB

        for frame in 0..<count {
            var peak: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let v = buf[frame]; let a = v < 0 ? -v : v; if a > peak { peak = a }
            }
            let xDB: Float     = peak > 1e-5 ? 20.0 * log10(peak) : -100.0
            var deltaDB: Float = xDB < thresh ? (thresh - xDB) * (1.0 - ratio) : 0.0
            if deltaDB < rangeDB { deltaDB = rangeDB }
            env = deltaDB < env
                ? alphaAtt * env + (1.0 - alphaAtt) * deltaDB
                : alphaRel * env + (1.0 - alphaRel) * deltaDB
            let gain = pow(10.0, env * 0.05)
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buf[frame] *= gain
            }
        }
        expEnvDB = env
    }

    // MARK: - Soft Clipper + Brickwall Limiter

    @inline(__always)
    private func processSoftClipperAndLimiter(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int,
        softOn: Bool, limOn: Bool
    ) {
        guard softOn || limOn else {
            _gainReductionBits.store(floatBits(0.0), ordering: .relaxed)
            return
        }

        let driveLinear  = bitsToFloat(_softClipperDrive.load(ordering: .relaxed))
        let threshold    = bitsToFloat(_softClipperThreshold.load(ordering: .relaxed))
        let knee         = bitsToFloat(_softClipperKnee.load(ordering: .relaxed))
        let ceiling      = bitsToFloat(_limiterCeiling.load(ordering: .relaxed))
        let alphaAttack  = bitsToFloat(_limiterAlphaAttack.load(ordering: .relaxed))
        let alphaRelease = bitsToFloat(_limiterAlphaRelease.load(ordering: .relaxed))

        let halfKnee   = knee * 0.5
        let xLower     = threshold - halfKnee
        let xUpper     = threshold + halfKnee
        let invTwoKnee = knee > 1e-9 ? 1.0 / (2.0 * knee) : 0.0
        let la         = max(1, min(lookAheadSize, Self.maxLookAheadSamples))
        var writeIdx   = lookAheadWriteIndex
        var gC         = limiterGainCurrent
        var lastGC     = gC
        var clipperWasActive = false

        for frame in 0..<count {
            if softOn {
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let input = buf[frame] * driveLinear
                    if abs(input) > xLower { clipperWasActive = true }
                    buf[frame] = softClip(input, threshold: threshold,
                                          xLower: xLower, xUpper: xUpper, invTwoKnee: invTwoKnee)
                }
            }
            if limOn {
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    lookAheadBufs[ch][writeIdx] = buf[frame]
                }
                var peakAmplitude: Float = 0.0
                for ch in 0..<numCh {
                    let p = scanPeak(lookAheadBufs[ch], size: la)
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
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    buf[frame] = lookAheadBufs[ch][readIdx] * gC
                }
                lastGC   = gC
                writeIdx = (writeIdx + 1) % la
            }
        }

        lookAheadWriteIndex = writeIdx
        limiterGainCurrent  = gC
        _clipperActiveBits.store(softOn && clipperWasActive ? 1 : 0, ordering: .relaxed)
        let grDB = lastGC > 1e-9 ? 20.0 * log10(lastGC) : Float(-90.0)
        _gainReductionBits.store(floatBits(grDB), ordering: .relaxed)
    }

    // MARK: - Inner DSP Helpers

    @inline(__always)
    private func softClip(
        _ x: Float, threshold: Float, xLower: Float, xUpper: Float, invTwoKnee: Float
    ) -> Float {
        let absX: Float = x < 0 ? -x : x
        let sign: Float = x >= 0 ? 1.0 : -1.0
        if absX <= xLower { return x }
        if absX > xUpper  { return sign * threshold }
        let delta = absX - xLower
        return sign * (xLower + delta - delta * delta * invTwoKnee)
    }

    @inline(__always)
    private func scanPeak(_ buffer: UnsafeMutablePointer<Float>, size: Int) -> Float {
        var peak: Float = 0.0
        for i in 0..<size { let v = buffer[i]; let a = v < 0 ? -v : v; if a > peak { peak = a } }
        return peak
    }

    /// Direct Form II Transposed biquad.
    /// na1 and na2 are stored as `-a1/a0` and `-a2/a0` (pre-negated) as returned by the coeff helpers.
    @inline(__always)
    private static func processBiquad(
        _ x: Float,
        b0: Float, b1: Float, b2: Float, na1: Float, na2: Float,
        w1: inout Float, w2: inout Float
    ) -> Float {
        let y = b0 * x + w1
        w1 = b1 * x + na1 * y + w2
        w2 = b2 * x + na2 * y
        return y
    }

    /// 2nd-order Butterworth LP coefficients (Q = 1/√2).
    /// Returns (b0, b1, b2, na1, na2) where na1/na2 are pre-negated for processBiquad.
    private static func lpfCoeffs(fc: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW * 0.7071067811865476          // sinW / (2Q), Q = 1/√2
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    = (1.0 - cosW) * 0.5 * a0inv
        let b1    = (1.0 - cosW) * a0inv
        let na1   =  2.0 * cosW * a0inv               // -a1/a0 = +2cosW/a0
        let na2   = -(1.0 - alpha) * a0inv             // -a2/a0
        return (b0, b1, b0, na1, na2)
    }

    /// 2nd-order Butterworth HP coefficients (Q = 1/√2).
    private static func hpfCoeffs(fc: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW * 0.7071067811865476
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    =  (1.0 + cosW) * 0.5 * a0inv
        let b1    = -(1.0 + cosW) * a0inv
        let na1   =  2.0 * cosW * a0inv
        let na2   = -(1.0 - alpha) * a0inv
        return (b0, b1, b0, na1, na2)
    }

    /// 2nd-order bandpass (constant 0 dB peak gain).
    private static func bpfCoeffs(fc: Float, q: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW / (2.0 * max(q, 0.1))
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    =  alpha * a0inv
        let b2    = -alpha * a0inv
        let na1   =  2.0 * cosW * a0inv
        let na2   = -(1.0 - alpha) * a0inv
        return (b0, 0.0, b2, na1, na2)
    }

    // MARK: - Static Helpers

    static func dbToLinear(_ db: Float) -> Float { pow(10.0, db / 20.0) }

    static func computeLookAheadSamples(sampleRate: Double, lookAheadMs: Float) -> Int {
        let samples = Int((sampleRate * Double(lookAheadMs) / 1000.0).rounded(.up))
        return min(max(1, samples), maxLookAheadSamples)
    }

    static func computeAlpha(tauSeconds: Float, sampleRate: Double) -> Float {
        Float(exp(-1.0 / (Double(tauSeconds) * sampleRate)))
    }
}

// MARK: - Bit-casting helpers (inline, no boxing)

@inline(__always)
private func floatBits(_ f: Float) -> Int32 { Int32(bitPattern: f.bitPattern) }

@inline(__always)
private func bitsToFloat(_ bits: Int32) -> Float { Float(bitPattern: UInt32(bitPattern: bits)) }
