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

    // Complementary LP/HP filter pairs for proper band splitting
    // Structure: [LP0, HP0, LP1, HP1, LP2, HP2, LP3, HP3] for 4 crossover points
    private nonisolated(unsafe) var bandFilters: [BiquadFilter]
    private nonisolated(unsafe) var bandEnvelopes: [Float]
    private nonisolated(unsafe) var bandGains: [Float]
    private nonisolated(unsafe) var bandCeilings: [Float]

    // Scratch buffers for per-band processing (one buffer per band)
    private nonisolated(unsafe) var bandBuffers: [UnsafeMutablePointer<Float>]
    private let maxFrameCount: Int

    private let sampleRate: Double
    private let bandCount = 5

    // MARK: - Initialization

    init(config: ExcursionProtectionConfig, baseCeilingDB: Float, sampleRate: Double, maxFrameCount: Int = 4096) {
        self.sampleRate = sampleRate
        self.maxFrameCount = maxFrameCount

        // Initialize complementary LP/HP filter pairs (Linkwitz-Riley 4th-order at each crossover point)
        // Crossover frequencies at Fs/4, Fs, 3×Fs, protectionCutoffHz
        let fs = Double(config.driverFsHz)
        let crossoverFrequencies: [Double] = [fs / 4.0, fs, fs * 3.0, Double(config.protectionCutoffHz)]

        // Create LP/HP pairs - LR4 uses two cascaded 2nd-order Butterworth sections per side
        bandFilters = []
        for freq in crossoverFrequencies {
            // Low-pass filter (2 cascaded sections for LR4)
            let lpFilter = BiquadFilter()
            let lpCoeffs = BiquadMath.calculateSections(
                type: .lowPass,
                sampleRate: sampleRate,
                frequency: freq,
                q: 0.7071067811865476,  // Butterworth Q
                gain: 0.0,
                slope: .db24  // 24 dB/oct = 4th order = LR4
            )
            lpFilter.stageCoefficients(lpCoeffs, resetState: true)
            lpFilter.applyPendingSetup()
            bandFilters.append(lpFilter)

            // High-pass filter (2 cascaded sections for LR4)
            let hpFilter = BiquadFilter()
            let hpCoeffs = BiquadMath.calculateSections(
                type: .highPass,
                sampleRate: sampleRate,
                frequency: freq,
                q: 0.7071067811865476,  // Butterworth Q
                gain: 0.0,
                slope: .db24  // 24 dB/oct = 4th order = LR4
            )
            hpFilter.stageCoefficients(hpCoeffs, resetState: true)
            hpFilter.applyPendingSetup()
            bandFilters.append(hpFilter)
        }

        // Allocate scratch buffers for per-band processing
        bandBuffers = crossoverFrequencies.map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
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

    deinit {
        // Free allocated scratch buffers
        for buffer in bandBuffers {
            buffer.deallocate()
        }
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

        // Rebuild complementary LP/HP filter pairs
        for (i, freq) in crossoverFrequencies.enumerated() {
            // Low-pass filter (2 cascaded sections for LR4)
            let lpCoeffs = BiquadMath.calculateSections(
                type: .lowPass,
                sampleRate: sampleRate,
                frequency: freq,
                q: 0.7071067811865476,  // Butterworth Q
                gain: 0.0,
                slope: .db24  // 24 dB/oct = 4th order = LR4
            )
            bandFilters[i * 2].stageCoefficients(lpCoeffs, resetState: false)
            bandFilters[i * 2].applyPendingSetup()

            // High-pass filter (2 cascaded sections for LR4)
            let hpCoeffs = BiquadMath.calculateSections(
                type: .highPass,
                sampleRate: sampleRate,
                frequency: freq,
                q: 0.7071067811865476,  // Butterworth Q
                gain: 0.0,
                slope: .db24  // 24 dB/oct = 4th order = LR4
            )
            bandFilters[i * 2 + 1].stageCoefficients(hpCoeffs, resetState: false)
            bandFilters[i * 2 + 1].applyPendingSetup()
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
            sqrt(crossoverFrequencies[2] * crossoverFrequencies[3]),
            crossoverFrequencies[3] * 2.0
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
        guard frameCount <= maxFrameCount else { return }

        let attackAlpha: Float = 0.01  // Fast attack for excursion protection
        let releaseAlpha: Float = 0.1   // Moderate release

        // Save original input (we need it for each band's filtering)
        let inputBuffer = bandBuffers[0]  // Use first band buffer as temp storage
        memcpy(inputBuffer, buffer, frameCount * MemoryLayout<Float>.size)

        // Clear output buffer (will be reconstructed from band sums)
        memset(buffer, 0, frameCount * MemoryLayout<Float>.size)

        // Process each band with proper splitting and recombination
        for bandIdx in 0..<bandCount {
            var envelope = bandEnvelopes[bandIdx]
            var gain = bandGains[bandIdx]
            let ceiling = bandCeilings[bandIdx]
            let bandBuffer = bandBuffers[bandIdx]

            // Copy input to band buffer for filtering
            memcpy(bandBuffer, inputBuffer, frameCount * MemoryLayout<Float>.size)

            // Apply filter cascade to isolate this band
            // Band structure (crossover frequencies at fs/4, fs, 3×fs, protectionCutoffHz):
            // Band 0: 0 to crossover[0] (LP0 only)
            // Band 1: crossover[0] to crossover[1] (HP0 then LP1)
            // Band 2: crossover[1] to crossover[2] (HP1 then LP2)
            // Band 3: crossover[2] to crossover[3] (HP2 then LP3)
            // Band 4: crossover[3] to ∞ (HP3 only - no protection, gain = 1.0 always)
            switch bandIdx {
            case 0:
                // Band 0: Just LP0 (very low frequencies)
                bandFilters[0].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
            case 1:
                // Band 1: HP0 then LP1 (low-mid frequencies)
                bandFilters[1].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
                bandFilters[2].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
            case 2:
                // Band 2: HP1 then LP2 (mid frequencies)
                bandFilters[3].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
                bandFilters[4].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
            case 3:
                // Band 3: HP2 then LP3 (high-mid frequencies)
                bandFilters[5].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
                bandFilters[6].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
            case 4:
                // Band 4: HP3 only (frequencies above protectionCutoffHz)
                // This band should have NO protection (gain = 1.0 always)
                bandFilters[7].process(input: bandBuffer, output: bandBuffer, frameCount: UInt32(frameCount))
            default:
                break
            }

            // Compute envelope and apply gain reduction to the isolated band
            for i in 0..<frameCount {
                let sample = bandBuffer[i]

                // Band 4 (above protectionCutoffHz) has no protection - pass through
                if bandIdx == 4 {
                    bandBuffer[i] = sample
                    continue
                }

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

                // Apply gain to this band's sample
                bandBuffer[i] = sample * gain
            }

            // Sum this band's processed output into the main buffer
            for i in 0..<frameCount {
                buffer[i] += bandBuffer[i]
            }

            bandEnvelopes[bandIdx] = envelope
            bandGains[bandIdx] = gain
        }
    }
}
