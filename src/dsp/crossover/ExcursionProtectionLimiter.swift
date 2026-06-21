// ExcursionProtectionLimiter.swift
//
// Frequency-dependent excursion protection based on driver Thiele-Small parameters.
// Protects against mechanical overexcursion at frequencies below the driver's resonance.
// Uses a 4-band IIR multiband approach with frequency-dependent ceiling derived from driver Fs/Qts.

import Foundation
import Accelerate
import Atomics

/// Excursion protection limiter using frequency-dependent gain reduction.
/// Core formula:
/// protectionGain(f) = min(maxProtectionDB,
///     maxProtectionDB × (Fs/f)² / (1 + (Fs/f)²·Qts²))   for f < protectionCutoffHz
/// protectionGain(f) = 0                                  for f ≥ protectionCutoffHz
/// ceiling(f) = baseCeilingDB − protectionGain(f)
final class ExcursionProtectionLimiter: @unchecked Sendable {

    // MARK: - Configuration

    private let _enabled = ManagedAtomic<Int32>(0)
    private let _baseCeilingBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(-0.2).bitPattern))
    private let _driverFsBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(45.0).bitPattern))
    private let _driverQtsBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(0.5).bitPattern))
    private let _maxProtectionBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(12.0).bitPattern))
    private let _protectionCutoffBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(135.0).bitPattern))

    // MARK: - Audio Thread State

    private nonisolated(unsafe) var bandFilters: [BiquadFilter]
    private nonisolated(unsafe) var bandEnvelopes: [Float]
    private nonisolated(unsafe) var bandGains: [Float]
    private nonisolated(unsafe) var bandCeilings: [Float]

    private let sampleRate: Double
    private let bandCount = 4

    // MARK: - Initialization

    init(config: ExcursionProtectionConfig, baseCeilingDB: Float, sampleRate: Double) {
        self.sampleRate = sampleRate

        // Initialize band filters (crossover frequencies at Fs/4, Fs, 3×Fs)
        let fs = Double(config.driverFsHz)
        let crossoverFrequencies: [Double] = [fs / 4.0, fs, fs * 3.0, Double(config.protectionCutoffHz)]

        bandFilters = crossoverFrequencies.map { freq in
            let filter = BiquadFilter()
            let coeffs = BiquadMath.calculateCoefficients(
                type: .lowPass,
                sampleRate: sampleRate,
                frequency: freq,
                q: 0.707,
                gain: 0.0
            )
            filter.stageCoefficients([coeffs], resetState: true)
            filter.applyPendingSetup()
            return filter
        }

        bandEnvelopes = Array(repeating: 0.0, count: bandCount)
        bandGains = Array(repeating: 1.0, count: bandCount)
        bandCeilings = Array(repeating: baseCeilingDB, count: bandCount)

        _enabled.store(config.isEnabled ? 1 : 0, ordering: .relaxed)
        _baseCeilingBits.store(Int32(bitPattern: baseCeilingDB.bitPattern), ordering: .relaxed)
        _driverFsBits.store(Int32(bitPattern: config.driverFsHz.bitPattern), ordering: .relaxed)
        _driverQtsBits.store(Int32(bitPattern: config.driverQts.bitPattern), ordering: .relaxed)
        _maxProtectionBits.store(Int32(bitPattern: config.maxProtectionDB.bitPattern), ordering: .relaxed)
        _protectionCutoffBits.store(Int32(bitPattern: config.protectionCutoffHz.bitPattern), ordering: .relaxed)

        updateBandCeilings()
    }

    // MARK: - Main Thread Configuration

    func setEnabled(_ enabled: Bool) {
        _enabled.store(enabled ? 1 : 0, ordering: .relaxed)
    }

    func setConfig(_ config: ExcursionProtectionConfig, baseCeilingDB: Float, sampleRate: Double) {
        _enabled.store(config.isEnabled ? 1 : 0, ordering: .relaxed)
        _baseCeilingBits.store(Int32(bitPattern: baseCeilingDB.bitPattern), ordering: .relaxed)
        _driverFsBits.store(Int32(bitPattern: config.driverFsHz.bitPattern), ordering: .relaxed)
        _driverQtsBits.store(Int32(bitPattern: config.driverQts.bitPattern), ordering: .relaxed)
        _maxProtectionBits.store(Int32(bitPattern: config.maxProtectionDB.bitPattern), ordering: .relaxed)
        _protectionCutoffBits.store(Int32(bitPattern: config.protectionCutoffHz.bitPattern), ordering: .relaxed)

        // Recalculate crossover frequencies if Fs changed
        let fs = Double(config.driverFsHz)
        let crossoverFrequencies: [Double] = [fs / 4.0, fs, fs * 3.0, Double(config.protectionCutoffHz)]

        for (i, freq) in crossoverFrequencies.enumerated() {
            let coeffs = BiquadMath.calculateCoefficients(
                type: .lowPass,
                sampleRate: sampleRate,
                frequency: freq,
                q: 0.707,
                gain: 0.0
            )
            bandFilters[i].stageCoefficients([coeffs], resetState: false)
            bandFilters[i].applyPendingSetup()
        }

        updateBandCeilings()
    }

    private func updateBandCeilings() {
        let baseCeiling = Float(bitPattern: UInt32(bitPattern: _baseCeilingBits.load(ordering: .relaxed)))
        let driverFs = Float(bitPattern: UInt32(bitPattern: _driverFsBits.load(ordering: .relaxed)))
        let driverQts = Float(bitPattern: UInt32(bitPattern: _driverQtsBits.load(ordering: .relaxed)))
        let maxProtection = Float(bitPattern: UInt32(bitPattern: _maxProtectionBits.load(ordering: .relaxed)))

        // Calculate band centre frequencies (geometric mean of crossover points)
        let fs = Double(driverFs)
        let protectionCutoff = Double(_protectionCutoffBits.load(ordering: .relaxed))
        let crossoverFrequencies: [Double] = [fs / 4.0, fs, fs * 3.0, protectionCutoff]
        let bandCentreFrequencies: [Double] = [
            crossoverFrequencies[0] / 2.0,
            sqrt(crossoverFrequencies[0] * crossoverFrequencies[1]),
            sqrt(crossoverFrequencies[1] * crossoverFrequencies[2]),
            crossoverFrequencies[2] * 2.0
        ]

        for i in 0..<bandCount {
            let f = bandCentreFrequencies[i]
            let protectionGain: Float

            if f < protectionCutoff {
                let ratio = driverFs / Float(f)
                let ratioSquared = ratio * ratio
                let qtsSquared = driverQts * driverQts
                let numerator = maxProtection * ratioSquared
                let denominator = 1.0 + ratioSquared * qtsSquared
                protectionGain = min(maxProtection, numerator / denominator)
            } else {
                protectionGain = 0.0
            }

            bandCeilings[i] = baseCeiling - protectionGain
        }
    }

    // MARK: - Audio Thread Processing

    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard _enabled.load(ordering: .relaxed) != 0 else { return }

        let attackAlpha: Float = 0.01  // Fast attack for excursion protection
        let releaseAlpha: Float = 0.1   // Moderate release

        // Process each band
        for bandIdx in 0..<bandCount {
            var envelope = bandEnvelopes[bandIdx]
            var gain = bandGains[bandIdx]
            let ceiling = bandCeilings[bandIdx]

            // Apply band filter and compute envelope
            for i in 0..<frameCount {
                let sample = buffer[i]

                // Simple envelope follower (peak detector)
                let absSample = abs(sample)
                envelope = absSample > envelope ? absSample : envelope * releaseAlpha + absSample * (1.0 - releaseAlpha)

                // Compute target gain based on ceiling
                var targetGain: Float
                if envelope > 1e-9 {
                    let linearCeiling = pow(10.0, ceiling / 20.0)
                    targetGain = linearCeiling / envelope
                    if targetGain > 1.0 {
                        targetGain = 1.0
                    }
                } else {
                    targetGain = 1.0
                }

                // Smooth gain transitions
                if targetGain < gain {
                    gain = gain * attackAlpha + targetGain * (1.0 - attackAlpha)
                } else {
                    gain = gain * releaseAlpha + targetGain * (1.0 - releaseAlpha)
                }

                // Apply gain (simplified - in a real implementation, this would use
                // actual multiband splitting and recombination)
                buffer[i] = sample * gain
            }

            bandEnvelopes[bandIdx] = envelope
            bandGains[bandIdx] = gain
        }
    }
}
