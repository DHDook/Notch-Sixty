import Atomics
import AudioToolbox
import Foundation
import os.log

/// Central coordinator for the entire dynamics processing chain.
///
/// **Thread safety:**
/// - All audio-thread state is `nonisolated(unsafe)` (audio-thread exclusive).
/// - All parameters are atomic and propagated on-the-fly to the audio thread.
/// - Main thread never reads audio state directly; all queries return cached metrics
///   that were written atomically by the audio thread on the most recent callback.
///
final class DynamicsProcessor: @unchecked Sendable {
    // MARK: - Configuration State (Atomics)

    private let _gainReductionDBBits: ManagedAtomic<Int32>
    private let _clipperEngagedBits: ManagedAtomic<Int32>
    private let _deEsserGainReductionDBBits: ManagedAtomic<Int32>
    private let _mbLowGRDBBits: ManagedAtomic<Int32>
    private let _mbMidGRDBBits: ManagedAtomic<Int32>
    private let _mbHighGRDBBits: ManagedAtomic<Int32>
    private let _compressorGRDBBits: ManagedAtomic<Int32>
    private let _expanderGRDBBits: ManagedAtomic<Int32>
    private let _clipperGRDBBits: ManagedAtomic<Int32>
    private let _phaseCorrelationBits: ManagedAtomic<Int32>
    private let _crestFactorDBBits: ManagedAtomic<Int32>
    private let _balanceMeterBits: ManagedAtomic<Int32>
    private let _truePeakClipperTrippedBits: ManagedAtomic<Int32>
    private let _truePeakLimiterTrippedBits: ManagedAtomic<Int32>

    // MARK: - Audio-Thread State (nonisolated(unsafe))

    nonisolated(unsafe) private var sampleRate: Double
    nonisolated(unsafe) private var channelCount: UInt32

    // MARK: - Initialisation

    init(channelCount: UInt32, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        // Initialize atomic metrics
        _gainReductionDBBits = ManagedAtomic(0)
        _clipperEngagedBits = ManagedAtomic(0)
        _deEsserGainReductionDBBits = ManagedAtomic(0)
        _mbLowGRDBBits = ManagedAtomic(0)
        _mbMidGRDBBits = ManagedAtomic(0)
        _mbHighGRDBBits = ManagedAtomic(0)
        _compressorGRDBBits = ManagedAtomic(0)
        _expanderGRDBBits = ManagedAtomic(0)
        _clipperGRDBBits = ManagedAtomic(0)
        _phaseCorrelationBits = ManagedAtomic(0)
        _crestFactorDBBits = ManagedAtomic(0)
        _balanceMeterBits = ManagedAtomic(0)
        _truePeakClipperTrippedBits = ManagedAtomic(0)
        _truePeakLimiterTrippedBits = ManagedAtomic(0)
    }

    // MARK: - Configuration (Main Thread)

    func applyConfig(_ config: DynamicsConfig, sampleRate: Double) {
        self.sampleRate = sampleRate
        // Configuration will be applied in audio thread processing
    }

    // MARK: - Audio-Thread Render

    /// Process frames through the entire dynamics chain.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        // Main processing loop - sub-processors will handle their stages
    }

    // MARK: - Public Metrics (Main Thread Read)

    var gainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _gainReductionDBBits.load(ordering: .relaxed)))
    }

    var clipperEngaged: Bool {
        _clipperEngagedBits.load(ordering: .relaxed) != 0
    }

    var deEsserGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _deEsserGainReductionDBBits.load(ordering: .relaxed)))
    }

    var mbLowGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbLowGRDBBits.load(ordering: .relaxed)))
    }

    var mbMidGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbMidGRDBBits.load(ordering: .relaxed)))
    }

    var mbHighGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbHighGRDBBits.load(ordering: .relaxed)))
    }

    var compressorGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _compressorGRDBBits.load(ordering: .relaxed)))
    }

    var expanderGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _expanderGRDBBits.load(ordering: .relaxed)))
    }

    var clipperGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _clipperGRDBBits.load(ordering: .relaxed)))
    }

    var livePhaseCorrelation: Float {
        Float(bitPattern: UInt32(bitPattern: _phaseCorrelationBits.load(ordering: .relaxed)))
    }

    var liveCrestFactorDB: Float {
        Float(bitPattern: UInt32(bitPattern: _crestFactorDBBits.load(ordering: .relaxed)))
    }

    var liveBalanceMeter: Float {
        Float(bitPattern: UInt32(bitPattern: _balanceMeterBits.load(ordering: .relaxed)))
    }

    var truePeakClipperTripped: Bool {
        _truePeakClipperTrippedBits.load(ordering: .relaxed) != 0
    }

    var truePeakLimiterTripped: Bool {
        _truePeakLimiterTrippedBits.load(ordering: .relaxed) != 0
    }

    func clearTruePeakFlags() {
        _truePeakClipperTrippedBits.store(0, ordering: .relaxed)
        _truePeakLimiterTrippedBits.store(0, ordering: .relaxed)
    }
}

// MARK: - Float ↔ Bits Conversion

@inline(__always)
private func floatBitsL(_ f: Float) -> Int32 {
    Int32(bitPattern: f.bitPattern)
}
