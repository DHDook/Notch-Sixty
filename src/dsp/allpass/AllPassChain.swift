// AllPassChain.swift
// Cascaded all-pass biquad sections for mixed-phase phase correction.
// One instance per channel. Updated from the main thread via double-buffered
// coefficient staging, identical to EQChain.

import Atomics
import Foundation

/// A single all-pass biquad section with its per-sample state.
private struct AllPassSection {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
    var w1: Float = 0, w2: Float = 0   // Direct-Form II transposed state
}

/// Fitted all-pass parameters for Phase 2 optimization.
struct FittedAllPassParams: Equatable {
    var frequency: Double  // Center frequency in Hz
    var q: Double         // Quality factor
}

/// Cascaded all-pass IIR filter for group-delay correction.
/// Lock-free double-buffered coefficient update, audio-thread safe.
final class AllPassChain: @unchecked Sendable {

    // Maximum number of all-pass sections (one per biquad section across all bands).
    // Supports up to 32 bands × 8 sections (96 dB/oct HP/LP) = 256 sections.
    // In practice: 32 bands × ≤8 sections at the absolute maximum slope.
    private static let maxSections = 256

    // Phase 2: Number of all-pass sections to fit per band (default: 2)
    private static let fittedSectionsPerBand = 2

    // Phase 2: Cache for fitted all-pass sections
    nonisolated(unsafe) private static var fittedSectionsCache: [String: [FittedAllPassParams]] = [:]
    private static let cacheLock = NSLock()

    // Pre-allocated flat storage — no heap allocation on the audio thread.
    private let activeStore:  UnsafeMutablePointer<AllPassSection>
    private let pendingStore: UnsafeMutablePointer<AllPassSection>
    nonisolated(unsafe) private var activeCount:  Int = 0
    private var pendingCount: Int = 0
    private let hasPending = ManagedAtomic<Bool>(false)

    init() {
        activeStore  = .allocate(capacity: Self.maxSections)
        activeStore.initialize(repeating: AllPassSection(), count: Self.maxSections)
        pendingStore = .allocate(capacity: Self.maxSections)
        pendingStore.initialize(repeating: AllPassSection(), count: Self.maxSections)
    }

    deinit {
        activeStore.deinitialize(count: Self.maxSections)
        activeStore.deallocate()
        pendingStore.deinitialize(count: Self.maxSections)
        pendingStore.deallocate()
    }

    // MARK: - Main Thread API

    /// Stages a new set of all-pass sections derived from the biquad band coefficients.
    /// Called from the main thread only.
    ///
    /// Phase 1 guard: only stages all-pass sections that measurably improve group delay.
    /// Phase 2: For each band, attempts to fit optimized all-pass sections that reduce
    /// group delay deviation, falling back to Phase 1 behavior if fitting fails.
    ///
    /// - Parameters:
    ///   - sectionSets: One `[BiquadCoefficients]` array per active band.
    ///     Bypassed bands must be excluded by the caller.
    ///   - sampleRate: Current audio sample rate (Hz).
    func stageSections(from sectionSets: [[BiquadCoefficients]], sampleRate: Double) {
        var count = 0
        for sections in sectionSets {
            // Phase 2: Try to fit optimized all-pass sections for this band
            let fittedParams = Self.fitAllPassSectionsForBand(biquadSections: sections, sampleRate: sampleRate)

            if let fittedParams = fittedParams {
                // Convert fitted parameters to all-pass sections
                for params in fittedParams {
                    guard count < Self.maxSections else { break }
                    let allPassSec = Self.allPassSectionFromParams(frequency: params.frequency, q: params.q, sampleRate: sampleRate)

                    // Phase 1 guard: only emit if it measurably improves group delay
                    if Self.allPassSectionImprovesGroupDelayForChain(
                        biquadSections: sections,
                        allPassSection: allPassSec,
                        sampleRate: sampleRate
                    ) {
                        pendingStore[count] = allPassSec
                        count += 1
                    }
                }
            } else {
                // Phase 1 fallback: use the simple construction for each section
                for sec in sections {
                    guard count < Self.maxSections else { break }

                    // Phase 1 guard: only emit all-pass section if it measurably improves group delay
                    if Self.allPassSectionImprovesGroupDelay(biquad: sec, sampleRate: sampleRate) {
                        pendingStore[count] = Self.allPassSection(from: sec)
                        count += 1
                    }
                }
            }
        }
        pendingCount = count
        hasPending.store(true, ordering: .releasing)
    }

    // MARK: - Audio Thread API

    /// Applies pending coefficient update if one is waiting.
    /// Call once per render cycle before `process()`.
    @inline(__always)
    func applyPendingUpdates() {
        guard hasPending.load(ordering: .acquiring) else { return }
        // Copy section data — no heap allocation, just a memcpy.
        let bytes = pendingCount * MemoryLayout<AllPassSection>.stride
        activeStore.withMemoryRebound(to: UInt8.self, capacity: bytes) { dst in
            pendingStore.withMemoryRebound(to: UInt8.self, capacity: bytes) { src in
                dst.update(from: src, count: bytes)
            }
        }
        activeCount = pendingCount
        hasPending.store(false, ordering: .relaxed)
    }

    /// Processes `frameCount` samples in-place through all active all-pass sections.
    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: UInt32) {
        guard activeCount > 0 else { return }
        for i in 0..<activeCount {
            processSingleSection(sectionIdx: i, buffer: buffer, frameCount: frameCount)
        }
    }

    // MARK: - Private

    @inline(__always)
    private func processSingleSection(
        sectionIdx: Int,
        buffer: UnsafeMutablePointer<Float>,
        frameCount: UInt32
    ) {
        let b0 = activeStore[sectionIdx].b0
        let b1 = activeStore[sectionIdx].b1
        let b2 = activeStore[sectionIdx].b2
        let a1 = activeStore[sectionIdx].a1
        let a2 = activeStore[sectionIdx].a2
        var w1 = activeStore[sectionIdx].w1
        var w2 = activeStore[sectionIdx].w2

        // Direct-Form II Transposed
        for n in 0..<Int(frameCount) {
            let x = buffer[n]
            let y = b0 * x + w1
            w1 = b1 * x - a1 * y + w2
            w2 = b2 * x - a2 * y
            buffer[n] = y
        }
        activeStore[sectionIdx].w1 = w1
        activeStore[sectionIdx].w2 = w2
    }

    /// Constructs an all-pass biquad from a source biquad's denominator coefficients.
    ///
    /// For a 2nd-order section: H_AP(z) = (a2 + a1·z⁻¹ + 1·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)
    /// For a 1st-order degenerate section (a2 == 0): H_AP(z) = (a1 + z⁻¹) / (1 + a1·z⁻¹)
    private static func allPassSection(from sec: BiquadCoefficients) -> AllPassSection {
        let isFirstOrder = abs(sec.a2) < 1e-12 && abs(sec.b2) < 1e-12
        if isFirstOrder {
            return AllPassSection(
                b0: Float(sec.a1),
                b1: 1.0,
                b2: 0.0,
                a1: Float(sec.a1),
                a2: 0.0
            )
        } else {
            return AllPassSection(
                b0: Float(sec.a2),
                b1: Float(sec.a1),
                b2: 1.0,
                a1: Float(sec.a1),
                a2: Float(sec.a2)
            )
        }
    }

    /// Constructs an all-pass biquad from fitted parameters (frequency, Q).
    ///
    /// Uses the RBJ all-pass cookbook formula to convert (f0, Q) to coefficients.
    private static func allPassSectionFromParams(frequency: Double, q: Double, sampleRate: Double) -> AllPassSection {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let b0 = 1.0 - alpha
        let b1 = -2.0 * cosOmega
        let b2 = 1.0 + alpha
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        // Normalize by a0
        let norm = 1.0 / a0

        return AllPassSection(
            b0: Float(b0 * norm),
            b1: Float(b1 * norm),
            b2: Float(b2 * norm),
            a1: Float(a1 * norm),
            a2: Float(a2 * norm)
        )
    }

    // MARK: - Phase 1 Group Delay Guard

    /// Evaluates whether cascading an all-pass section with the given biquad
    /// measurably improves group delay (reduces peak deviation from median).
    ///
    /// - Parameters:
    ///   - biquad: The biquad coefficients to test.
    ///   - sampleRate: Audio sample rate in Hz.
    /// - Returns: true if the all-pass section improves group delay, false otherwise.
    private static func allPassSectionImprovesGroupDelay(biquad: BiquadCoefficients, sampleRate: Double) -> Bool {
        // Compute group delay of biquad alone
        let gdBiquad = computeGroupDelay(biquad: biquad, sampleRate: sampleRate)
        let peakDeviationBiquad = peakGroupDelayDeviation(groupDelay: gdBiquad)

        // Compute group delay of biquad + all-pass
        let allPass = allPassSection(from: biquad)
        let gdCombined = computeGroupDelayCombined(biquad: biquad, allPass: allPass, sampleRate: sampleRate)
        let peakDeviationCombined = peakGroupDelayDeviation(groupDelay: gdCombined)

        // Only emit the all-pass section if it reduces peak deviation
        return peakDeviationCombined < peakDeviationBiquad
    }

    /// Computes group delay across a log-spaced frequency grid (20 Hz - 20 kHz).
    private static func computeGroupDelay(biquad: BiquadCoefficients, sampleRate: Double) -> [Double] {
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)
        return frequencies.map { freq in
            groupDelayAtFrequency(biquad: biquad, frequency: freq, sampleRate: sampleRate)
        }
    }

    /// Computes group delay of biquad cascaded with all-pass section.
    private static func computeGroupDelayCombined(biquad: BiquadCoefficients, allPass: AllPassSection, sampleRate: Double) -> [Double] {
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)
        return frequencies.map { freq in
            let gdBiquad = groupDelayAtFrequency(biquad: biquad, frequency: freq, sampleRate: sampleRate)
            let gdAllPass = groupDelayAtFrequency(allPass: allPass, frequency: freq, sampleRate: sampleRate)
            return gdBiquad + gdAllPass
        }
    }

    /// Computes group delay at a single frequency for a biquad filter.
    private static func groupDelayAtFrequency(biquad: BiquadCoefficients, frequency: Double, sampleRate: Double) -> Double {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)

        let b0 = biquad.b0, b1 = biquad.b1, b2 = biquad.b2
        let a1 = biquad.a1, a2 = biquad.a2

        // Numerator and denominator of H(z) at z = e^(jω)
        let numReal = b0 + b1 * cosOmega + b2 * cos(2.0 * omega)
        let numImag = b1 * sinOmega + b2 * sin(2.0 * omega)
        let denReal = 1.0 + a1 * cosOmega + a2 * cos(2.0 * omega)
        let denImag = a1 * sinOmega + a2 * sin(2.0 * omega)

        // Derivatives with respect to ω
        let numRealDeriv = -b1 * sinOmega - 2.0 * b2 * sin(2.0 * omega)
        let numImagDeriv = b1 * cosOmega + 2.0 * b2 * cos(2.0 * omega)
        let denRealDeriv = -a1 * sinOmega - 2.0 * a2 * sin(2.0 * omega)
        let denImagDeriv = a1 * cosOmega + 2.0 * a2 * cos(2.0 * omega)

        // Group delay = Re( (H' * conj(H)) / |H|^2 )
        let hReal = numReal * denReal + numImag * denImag
        let hImag = numImag * denReal - numReal * denImag
        let hMagSq = denReal * denReal + denImag * denImag

        let hRealDeriv = numRealDeriv * denReal + numImagDeriv * denImag - numReal * denRealDeriv - numImag * denImagDeriv
        let hImagDeriv = numImagDeriv * denReal - numRealDeriv * denImag - numImag * denRealDeriv + numReal * denImagDeriv

        let groupDelay = (hRealDeriv * hReal + hImagDeriv * hImag) / (hMagSq * hMagSq + 1e-30)

        return groupDelay
    }

    /// Computes group delay at a single frequency for an all-pass section.
    private static func groupDelayAtFrequency(allPass: AllPassSection, frequency: Double, sampleRate: Double) -> Double {
        let biquad = BiquadCoefficients(
            b0: Double(allPass.b0),
            b1: Double(allPass.b1),
            b2: Double(allPass.b2),
            a1: Double(allPass.a1),
            a2: Double(allPass.a2)
        )
        return groupDelayAtFrequency(biquad: biquad, frequency: frequency, sampleRate: sampleRate)
    }

    /// Computes peak deviation of group delay from its median.
    private static func peakGroupDelayDeviation(groupDelay: [Double]) -> Double {
        guard !groupDelay.isEmpty else { return 0.0 }

        // Compute median
        let sorted = groupDelay.sorted()
        let median: Double
        let n = sorted.count
        if n % 2 == 0 {
            median = (sorted[n/2 - 1] + sorted[n/2]) / 2.0
        } else {
            median = sorted[n/2]
        }

        // Compute peak absolute deviation from median
        let deviations = groupDelay.map { abs($0 - median) }
        return deviations.max() ?? 0.0
    }

    /// Generates log-spaced frequencies from minFreq to maxFreq.
    private static func logSpacedFrequencies(minFreq: Double, maxFreq: Double, count: Int) -> [Double] {
        let logMin = log(minFreq)
        let logMax = log(maxFreq)
        let step = (logMax - logMin) / Double(count - 1)

        return (0..<count).map { i in
            exp(logMin + Double(i) * step)
        }
    }

    // MARK: - Phase 2 Fitted All-Pass Sections

    /// Fits optimized all-pass sections for a single band using numerical optimization.
    ///
    /// - Parameters:
    ///   - biquadSections: The biquad sections for this band.
    ///   - sampleRate: Audio sample rate in Hz.
    /// - Returns: Array of fitted (frequency, Q) parameters, or nil if fitting fails.
    internal static func fitAllPassSectionsForBand(biquadSections: [BiquadCoefficients], sampleRate: Double) -> [FittedAllPassParams]? {
        // Generate cache key from biquad coefficients
        let cacheKey = biquadSections.map { "\($0.b0),\($0.b1),\($0.b2),\($0.a1),\($0.a2)" }.joined(separator: "|")

        // Check cache
        cacheLock.lock()
        if let cached = fittedSectionsCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Compute target phase: φ_target(ω) = -φ_bands(ω)
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)
        let targetPhase = computeCombinedPhase(biquadSections: biquadSections, frequencies: frequencies, sampleRate: sampleRate)
            .map { -$0 }  // Target is negative of current phase

        // Fit N sections using simple coordinate search (simplified Nelder-Mead)
        let fittedParams = fitAllPassSectionsWithCoordinateSearch(
            biquadSections: biquadSections,
            targetPhase: targetPhase,
            frequencies: frequencies,
            sampleRate: sampleRate,
            numSections: fittedSectionsPerBand
        )

        // Cache result
        if let fitted = fittedParams {
            cacheLock.lock()
            fittedSectionsCache[cacheKey] = fitted
            cacheLock.unlock()
        }

        return fittedParams
    }

    /// Computes combined phase response of a biquad chain across frequencies.
    private static func computeCombinedPhase(biquadSections: [BiquadCoefficients], frequencies: [Double], sampleRate: Double) -> [Double] {
        return frequencies.map { freq in
            var totalPhase = 0.0
            for sec in biquadSections {
                totalPhase += phaseAtFrequency(biquad: sec, frequency: freq, sampleRate: sampleRate)
            }
            return totalPhase
        }
    }

    /// Computes phase response at a single frequency for a biquad.
    private static func phaseAtFrequency(biquad: BiquadCoefficients, frequency: Double, sampleRate: Double) -> Double {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)

        let b0 = biquad.b0, b1 = biquad.b1, b2 = biquad.b2
        let a1 = biquad.a1, a2 = biquad.a2

        let numReal = b0 + b1 * cosOmega + b2 * cos(2.0 * omega)
        let numImag = b1 * sinOmega + b2 * sin(2.0 * omega)
        let denReal = 1.0 + a1 * cosOmega + a2 * cos(2.0 * omega)
        let denImag = a1 * sinOmega + a2 * sin(2.0 * omega)

        return atan2(numImag, numReal) - atan2(denImag, denReal)
    }

    /// Fits all-pass sections using simplified coordinate search (gradient-free optimization).
    private static func fitAllPassSectionsWithCoordinateSearch(
        biquadSections: [BiquadCoefficients],
        targetPhase: [Double],
        frequencies: [Double],
        sampleRate: Double,
        numSections: Int
    ) -> [FittedAllPassParams]? {
        // Initial guess: center frequency at 1 kHz, Q = 1.0 for all sections
        var params = (0..<numSections).map { _ in
            FittedAllPassParams(frequency: 1000.0, q: 1.0)
        }

        // Simple coordinate descent: optimize each parameter in turn
        let iterations = 50
        let learningRate = 0.1

        for _ in 0..<iterations {
            var improved = false

            for i in 0..<numSections {
                // Optimize frequency
                let originalFreq = params[i].frequency
                let bestFreq = optimizeParameter(
                    params: params,
                    paramIndex: i,
                    isFrequency: true,
                    targetPhase: targetPhase,
                    frequencies: frequencies,
                    sampleRate: sampleRate,
                    originalValue: originalFreq,
                    learningRate: learningRate
                )

                if bestFreq != originalFreq {
                    params[i].frequency = bestFreq
                    improved = true
                }

                // Optimize Q
                let originalQ = params[i].q
                let bestQ = optimizeParameter(
                    params: params,
                    paramIndex: i,
                    isFrequency: false,
                    targetPhase: targetPhase,
                    frequencies: frequencies,
                    sampleRate: sampleRate,
                    originalValue: originalQ,
                    learningRate: learningRate
                )

                if bestQ != originalQ {
                    params[i].q = max(0.1, bestQ)  // Clamp Q to minimum 0.1
                    improved = true
                }
            }

            if !improved {
                break  // Converged
            }
        }

        // Verify the fitted sections actually improve group delay
        let allPassSections = params.map { allPassSectionFromParams(frequency: $0.frequency, q: $0.q, sampleRate: sampleRate) }

        // Compute group delay of biquad chain alone
        let gdBiquad = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: [], frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationBiquad = peakGroupDelayDeviation(groupDelay: gdBiquad)

        // Compute group delay with fitted all-pass sections
        let gdCombined = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: allPassSections, frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationCombined = peakGroupDelayDeviation(groupDelay: gdCombined)

        // Only return if improvement is significant (> 5%)
        if peakDeviationCombined < peakDeviationBiquad * 0.95 {
            return params
        }

        return nil  // Fitting didn't improve enough
    }

    /// Optimizes a single parameter using coordinate search.
    private static func optimizeParameter(
        params: [FittedAllPassParams],
        paramIndex: Int,
        isFrequency: Bool,
        targetPhase: [Double],
        frequencies: [Double],
        sampleRate: Double,
        originalValue: Double,
        learningRate: Double
    ) -> Double {
        let testValues = [
            originalValue * 0.8,
            originalValue * 0.9,
            originalValue,
            originalValue * 1.1,
            originalValue * 1.2
        ]

        var bestValue = originalValue
        var bestError = Double.infinity

        for testValue in testValues {
            // Clamp to valid ranges
            let clampedValue: Double
            if isFrequency {
                clampedValue = max(20.0, min(testValue, sampleRate * 0.4))  // 20 Hz to 0.4 * Nyquist
            } else {
                clampedValue = max(0.1, min(testValue, 20.0))  // Q: 0.1 to 20
            }

            var testParams = params
            if isFrequency {
                testParams[paramIndex].frequency = clampedValue
            } else {
                testParams[paramIndex].q = clampedValue
            }

            let error = computePhaseError(params: testParams, targetPhase: targetPhase, frequencies: frequencies, sampleRate: sampleRate)

            if error < bestError {
                bestError = error
                bestValue = clampedValue
            }
        }

        return bestValue
    }

    /// Computes phase error between target and fitted all-pass response.
    private static func computePhaseError(params: [FittedAllPassParams], targetPhase: [Double], frequencies: [Double], sampleRate: Double) -> Double {
        let allPassSections = params.map { allPassSectionFromParams(frequency: $0.frequency, q: $0.q, sampleRate: sampleRate) }
        let fittedPhase = computeCombinedPhase(allPassSections: allPassSections, frequencies: frequencies, sampleRate: sampleRate)

        // Compute L2 error
        var error: Double = 0
        for i in 0..<fittedPhase.count {
            let diff = fittedPhase[i] - targetPhase[i]
            error += diff * diff
        }

        return sqrt(error / Double(fittedPhase.count))
    }

    /// Computes combined phase response of all-pass sections.
    private static func computeCombinedPhase(allPassSections: [AllPassSection], frequencies: [Double], sampleRate: Double) -> [Double] {
        return frequencies.map { freq in
            var totalPhase = 0.0
            for sec in allPassSections {
                totalPhase += phaseAtFrequency(allPass: sec, frequency: freq, sampleRate: sampleRate)
            }
            return totalPhase
        }
    }

    /// Computes phase response at a single frequency for an all-pass section.
    private static func phaseAtFrequency(allPass: AllPassSection, frequency: Double, sampleRate: Double) -> Double {
        let biquad = BiquadCoefficients(
            b0: Double(allPass.b0),
            b1: Double(allPass.b1),
            b2: Double(allPass.b2),
            a1: Double(allPass.a1),
            a2: Double(allPass.a2)
        )
        return phaseAtFrequency(biquad: biquad, frequency: frequency, sampleRate: sampleRate)
    }

    /// Computes group delay for a chain of biquad and all-pass sections.
    private static func computeGroupDelayForChain(
        biquadSections: [BiquadCoefficients],
        allPassSections: [AllPassSection],
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        return frequencies.map { freq in
            var gd: Double = 0
            for sec in biquadSections {
                gd += groupDelayAtFrequency(biquad: sec, frequency: freq, sampleRate: sampleRate)
            }
            for sec in allPassSections {
                gd += groupDelayAtFrequency(allPass: sec, frequency: freq, sampleRate: sampleRate)
            }
            return gd
        }
    }

    /// Evaluates whether cascading an all-pass section with a biquad chain
    /// measurably improves group delay (reduces peak deviation from median).
    ///
    /// - Parameters:
    ///   - biquadSections: The biquad sections to test.
    ///   - allPassSection: The all-pass section to test.
    ///   - sampleRate: Audio sample rate in Hz.
    /// - Returns: true if the all-pass section improves group delay, false otherwise.
    private static func allPassSectionImprovesGroupDelayForChain(
        biquadSections: [BiquadCoefficients],
        allPassSection: AllPassSection,
        sampleRate: Double
    ) -> Bool {
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)

        // Compute group delay of biquad chain alone
        let gdBiquad = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: [], frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationBiquad = peakGroupDelayDeviation(groupDelay: gdBiquad)

        // Compute group delay of biquad chain + all-pass
        let gdCombined = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: [allPassSection], frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationCombined = peakGroupDelayDeviation(groupDelay: gdCombined)

        // Only emit the all-pass section if it reduces peak deviation
        return peakDeviationCombined < peakDeviationBiquad
    }

    /// Clears processing state (call when mode is disabled).
    func reset() {
        for i in 0..<activeCount {
            activeStore[i].w1 = 0
            activeStore[i].w2 = 0
        }
    }
}
