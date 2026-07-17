// AdaptiveExcessPhaseCorrector.swift
// Adaptive excess-phase correction for Mixed Phase EQ
//
// When all-pass correction alone cannot sufficiently flatten group delay,
// this module escalates to a linear-phase FIR correction targeting the residual excess phase.

import Accelerate
import Atomics
import Foundation

/// Adaptive excess-phase corrector that provides FIR correction when all-pass alone is insufficient.
final class AdaptiveExcessPhaseCorrector: @unchecked Sendable {

    // MARK: - Configuration

    /// Configuration for the adaptive corrector.
    struct Config: Equatable, Sendable {
        var enabled: Bool = false
        var kernelSize: Int = 4096  // Adaptive based on band characteristics
        var seamlessCrossfadeEnabled: Bool = true  // Enable dual-path crossfade for latency transitions
    }

    // MARK: - State

    private var config: Config
    private var sampleRate: Double

    // LinearPhaseEQEngine for realization (reused core machinery)
    private let linearPhaseEngine: LinearPhaseEQEngine

    // Optional seamless crossfade coordinator for latency transitions
    private var crossfadeCoordinator: SeamlessCrossfadeCoordinator?

    // Lock-free IR update mechanism
    private var hasPendingIR = ManagedAtomic<Bool>(false)

    /// The group delay introduced by the corrector in samples.
    /// Equal to kernelSize / 2 (the center of the causal kernel) when enabled, 0 when disabled.
    var correctorDelaySamples: Int {
        config.enabled ? config.kernelSize / 2 : 0
    }

    // MARK: - Initialization

    init(sampleRate: Double, maxFrameCount: Int) {
        self.sampleRate = sampleRate
        self.config = Config()
        self.linearPhaseEngine = LinearPhaseEQEngine(maxFrameCount: maxFrameCount)

        // Initialize crossfade coordinator if enabled
        if config.seamlessCrossfadeEnabled {
            self.crossfadeCoordinator = SeamlessCrossfadeCoordinator(
                sampleRate: sampleRate,
                maxFrameCount: maxFrameCount
            )
        }
    }

    // MARK: - Main Thread API

    /// Updates the correction filter based on the residual excess phase after all-pass fitting.
    ///
    /// - Parameters:
    ///   - biquadSections: All biquad sections across the active chain.
    ///   - allPassSections: The accepted all-pass sections (may be empty).
    ///   - sampleRate: Current audio sample rate in Hz.
    func updateCorrection(
        biquadSections: [BiquadCoefficients],
        allPassSections: [AllPassSection],
        sampleRate: Double
    ) {
        self.sampleRate = sampleRate

        // Compute adaptive kernel size based on band characteristics
        let kernelSize = computeAdaptiveKernelSize(
            biquadSections: biquadSections,
            sampleRate: sampleRate
        )

        // Compute target phase: unity magnitude, phase = -residual excess phase
        let targetPhase = computeTargetPhase(
            biquadSections: biquadSections,
            allPassSections: allPassSections,
            sampleRate: sampleRate
        )

        // Build FIR kernel from target phase
        let kernel = buildKernelFromTargetPhase(
            targetPhase: targetPhase,
            kernelSize: kernelSize,
            sampleRate: sampleRate
        )

        let previousDelaySamples = config.enabled ? config.kernelSize / 2 : 0
        let targetDelaySamples = kernelSize / 2

        // Use seamless crossfade coordinator if enabled and latency is changing
        if config.seamlessCrossfadeEnabled,
           let coordinator = crossfadeCoordinator,
           previousDelaySamples != targetDelaySamples {
            // Trigger seamless transition
            coordinator.triggerTransition(
                targetKernel: kernel,
                targetDelaySamples: targetDelaySamples,
                currentDelaySamples: previousDelaySamples
            )
        } else {
            // Direct update (no crossfade)
            linearPhaseEngine.updateIRFromKernel(
                leftKernel: kernel,
                rightKernel: kernel,
                sampleRate: sampleRate
            )
        }

        config.kernelSize = kernelSize
        config.enabled = true
        hasPendingIR.store(true, ordering: .releasing)
    }

    /// Disables the correction filter.
    func disable() {
        config.enabled = false
        hasPendingIR.store(true, ordering: .releasing)
    }

    // MARK: - Audio Thread API

    /// Applies pending coefficient update if one is waiting.
    @inline(__always)
    func applyPendingUpdates() {
        if hasPendingIR.load(ordering: .acquiring) {
            hasPendingIR.store(false, ordering: .relaxed)
        }
    }

    /// Processes audio through the correction filter.
    @inline(__always)
    func process(bufL: UnsafeMutablePointer<Float>,
                 bufR: UnsafeMutablePointer<Float>?,
                 frameCount: Int) {
        guard config.enabled else { return }

        // Use crossfade coordinator if available and in transition
        if let coordinator = crossfadeCoordinator, coordinator.currentState != .idle {
            coordinator.process(bufL: bufL, bufR: bufR, frameCount: frameCount)
        } else {
            // Direct processing through linear phase engine
            applyPendingUpdates()
            linearPhaseEngine.process(bufL: bufL, bufR: bufR, frameCount: frameCount)
        }
    }

    // MARK: - Private Helpers

    /// Computes adaptive kernel size based on band characteristics.
    private func computeAdaptiveKernelSize(
        biquadSections: [BiquadCoefficients],
        sampleRate: Double
    ) -> Int {
        // Find the lowest frequency / highest Q combination driving the residual deviation
        var minFreq = Double.infinity
        var maxQ = 0.0

        for sec in biquadSections {
            // Estimate frequency from coefficients
            // Guard against invalid coefficients (e.g., unity biquad)
            let a2Abs = abs(sec.a2)
            if a2Abs > 1e-9 && a2Abs < 1.0 {
                let omega0 = acos(-sec.a1 / (2 * sqrt(sec.a2)))
                if omega0.isFinite {
                    let freq = omega0 * sampleRate / (2 * .pi)
                    if freq > 20 && freq < sampleRate * 0.4 {
                        minFreq = min(minFreq, freq)
                    }
                }

                // Estimate Q from coefficients
                let q = 1.0 / (2 * sqrt(sec.a2))
                if q.isFinite {
                    maxQ = max(maxQ, q)
                }
            }
        }

        // If estimation failed, use conservative defaults
        if minFreq == Double.infinity || !minFreq.isFinite {
            minFreq = 100.0
        }
        if maxQ == 0 || !maxQ.isFinite {
            maxQ = 2.0
        }

        // Kernel size based on required frequency resolution
        // Higher Q and lower frequency require larger kernels
        let frequencyResolution = minFreq / maxQ
        let requiredSize = Int(sampleRate / frequencyResolution)

        // Round to power of 2 and clamp to reasonable range
        let baseSize = 4096
        let scaledSize = max(baseSize, requiredSize)
        let log2Value = log2(Double(scaledSize))
        guard log2Value.isFinite else {
            return baseSize
        }
        let powerOf2Size = 1 << Int(log2Value.rounded())

        return min(powerOf2Size, 32768)  // Cap at 32768
    }

    /// Computes target phase for the correction filter.
    private func computeTargetPhase(
        biquadSections: [BiquadCoefficients],
        allPassSections: [AllPassSection],
        sampleRate: Double
    ) -> [(frequency: Double, phase: Double)] {
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)

        // Compute combined phase of biquad + all-pass chain
        var combinedPhase: [Double] = []
        for freq in frequencies {
            var totalPhase = 0.0

            // Add biquad phase contributions
            for sec in biquadSections {
                totalPhase += AllPassChain.phaseAtFrequency(biquad: sec, frequency: freq, sampleRate: sampleRate)
            }

            // Add all-pass phase contributions
            for sec in allPassSections {
                let biquad = BiquadCoefficients(
                    b0: Double(sec.b0),
                    b1: Double(sec.b1),
                    b2: Double(sec.b2),
                    a1: Double(sec.a1),
                    a2: Double(sec.a2)
                )
                totalPhase += AllPassChain.phaseAtFrequency(biquad: biquad, frequency: freq, sampleRate: sampleRate)
            }

            combinedPhase.append(totalPhase)
        }

        // Compute median group delay for reference anchoring
        let gdCombined = combinedPhase.enumerated().map { (i, _) in
            groupDelayAtFrequency(biquadSections: biquadSections, allPassSections: allPassSections, frequency: frequencies[i], sampleRate: sampleRate)
        }
        let medianGD = median(gdCombined)

        // Target phase = -residual excess phase, anchored to median delay
        // residual = combinedPhase - medianGD * frequency
        var targetPhase: [(frequency: Double, phase: Double)] = []
        for (i, freq) in frequencies.enumerated() {
            let residualPhase = combinedPhase[i] - medianGD * 2.0 * .pi * freq / sampleRate
            let target = -residualPhase  // Negative of residual
            targetPhase.append((freq, target))
        }

        return targetPhase
    }

    /// Builds FIR kernel from target phase response.
    private func buildKernelFromTargetPhase(
        targetPhase: [(frequency: Double, phase: Double)],
        kernelSize: Int,
        sampleRate: Double
    ) -> [Float] {
        let fftSize = kernelSize
        let halfSize = fftSize / 2

        // Build target complex response: magnitude = 1, phase = targetPhase
        // FFTEngine.inverseFFT expects halfSize inputs
        var targetReal: [Float] = Array(repeating: 0.0, count: halfSize)
        var targetImag: [Float] = Array(repeating: 0.0, count: halfSize)

        for (i, point) in targetPhase.enumerated() {
            guard i < halfSize else { break }
            targetReal[i] = Float(cos(point.phase))
            targetImag[i] = Float(sin(point.phase))
        }

        // Inverse FFT to get time-domain impulse response
        let fftEngine = FFTEngine(fftSize: fftSize)
        var impulseResponse = fftEngine.inverseFFT(real: targetReal, imag: targetImag)

        // Apply Blackman-Harris windowing
        let window = blackmanHarrisWindow(size: fftSize)
        for i in 0..<fftSize {
            impulseResponse[i] *= window[i]
        }

        // Center the result to produce a causal linear-phase FIR
        let halfSizeInt = fftSize / 2
        var centeredResponse = Array(repeating: Float(0.0), count: fftSize)
        for i in 0..<fftSize {
            let srcIdx = (i + halfSizeInt) % fftSize
            centeredResponse[i] = impulseResponse[srcIdx]
        }

        return centeredResponse
    }

    /// Blackman-Harris window function.
    private func blackmanHarrisWindow(size: Int) -> [Float] {
        var window: [Float] = []
        let n = Float(size - 1)
        for i in 0..<size {
            let iFloat = Float(i)
            let w = 0.35875 - 0.48829 * cos(2.0 * .pi * iFloat / n) +
                      0.14128 * cos(4.0 * .pi * iFloat / n) -
                      0.01168 * cos(6.0 * .pi * iFloat / n)
            window.append(Float(w))
        }
        return window
    }

    /// Helper: computes group delay at frequency for combined chain.
    private func groupDelayAtFrequency(
        biquadSections: [BiquadCoefficients],
        allPassSections: [AllPassSection],
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        var gd: Double = 0
        for sec in biquadSections {
            gd += AllPassChain.groupDelayAtFrequency(biquad: sec, frequency: frequency, sampleRate: sampleRate)
        }
        for sec in allPassSections {
            let biquad = BiquadCoefficients(
                b0: Double(sec.b0),
                b1: Double(sec.b1),
                b2: Double(sec.b2),
                a1: Double(sec.a1),
                a2: Double(sec.a2)
            )
            gd += AllPassChain.groupDelayAtFrequency(biquad: biquad, frequency: frequency, sampleRate: sampleRate)
        }
        return gd
    }

    /// Helper: computes median of array.
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            return sorted[count / 2]
        }
    }

    /// Helper: log-spaced frequencies.
    private func logSpacedFrequencies(minFreq: Double, maxFreq: Double, count: Int) -> [Double] {
        let logMin = log(minFreq)
        let logMax = log(maxFreq)
        let step = (logMax - logMin) / Double(count - 1)
        return (0..<count).map { exp(logMin + Double($0) * step) }
    }
}

