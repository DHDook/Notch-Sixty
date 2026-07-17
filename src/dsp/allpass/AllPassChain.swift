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
    /// Phase 2: Fits and gates all-pass sections for the entire active chain,
    /// not per-band, to avoid whole-chain regression in multi-band use.
    ///
    /// - Parameters:
    ///   - sectionSets: One `[BiquadCoefficients]` array per active band.
    ///     Bypassed bands must be excluded by the caller.
    ///   - sampleRate: Current audio sample rate (Hz).
    func stageSections(from sectionSets: [[BiquadCoefficients]], sampleRate: Double) {
        let allBiquadSections = sectionSets.flatMap { $0 }
        guard !allBiquadSections.isEmpty else {
            pendingCount = 0
            hasPending.store(true, ordering: .releasing)
            return
        }

        // Budget scales with how many bands are active, capped at maxSections.
        let numSectionsToFit = min(Self.maxSections, max(2, sectionSets.count * 2))

        // Seed the multi-start grid around EVERY active band's frequency, not
        // just one — reuse the existing 3-multiplier x 3-Q pattern per band,
        // rather than only anchoring near a single band.
        let fittedParams = Self.fitAllPassSectionsForChain(
            biquadSections: allBiquadSections,
            bandFrequencyHints: sectionSets.map { Self.estimateBandFrequency(biquadSections: $0, sampleRate: sampleRate) },
            sampleRate: sampleRate,
            numSections: numSectionsToFit
        )

        var count = 0
        if let fittedParams = fittedParams {
            let candidateSections = fittedParams.map {
                Self.allPassSectionFromParams(frequency: $0.frequency, q: $0.q, sampleRate: sampleRate)
            }
            // Gate the WHOLE candidate set against the WHOLE active chain at once.
            if Self.allPassSectionsImproveGroupDelayForChain(
                biquadSections: allBiquadSections,
                allPassSections: candidateSections,
                sampleRate: sampleRate
            ) {
                for sec in candidateSections {
                    guard count < Self.maxSections else { break }
                    pendingStore[count] = sec
                    count += 1
                }
            }
            // If the combined set doesn't clear the threshold, accept nothing —
            // do not fall back to per-section acceptance of a partial subset,
            // and do not fall back to the reflection-based construction.
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

        let numReal = b0 + b1 * cosOmega + b2 * cos(2.0 * omega)
        let numImag = b1 * sinOmega + b2 * sin(2.0 * omega)
        let denReal = 1.0 + a1 * cosOmega + a2 * cos(2.0 * omega)
        let denImag = a1 * sinOmega + a2 * sin(2.0 * omega)

        let numRealDeriv = -b1 * sinOmega - 2.0 * b2 * sin(2.0 * omega)
        let numImagDeriv = b1 * cosOmega + 2.0 * b2 * cos(2.0 * omega)
        let denRealDeriv = -a1 * sinOmega - 2.0 * a2 * sin(2.0 * omega)
        let denImagDeriv = a1 * cosOmega + 2.0 * a2 * cos(2.0 * omega)

        let numMagSq = numReal * numReal + numImag * numImag
        let denMagSq = denReal * denReal + denImag * denImag

        // d(arg Num)/dω and d(arg Den)/dω, each via the standard
        // d(arg f)/dω = (Re(f)·Im(f)' - Im(f)·Re(f)') / |f|^2 identity.
        let dArgNum = (numReal * numImagDeriv - numImag * numRealDeriv) / (numMagSq + 1e-30)
        let dArgDen = (denReal * denImagDeriv - denImag * denRealDeriv) / (denMagSq + 1e-30)

        // groupDelay = +d(phase)/dω under this file's existing numImag/denImag
        // sign convention (phaseAtFrequency in this same file uses the same
        // convention, which is why this is `+` rather than the textbook `-dφ/dω`
        // — verified against a known-exact case: a pure z^-1 delay must give
        // exactly +1.0 here, and does with this sign).
        return dArgNum - dArgDen
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

    /// Evaluates a candidate parameter set using peak group delay deviation as the objective.
    private static func evaluateCandidate(
        biquadSections: [BiquadCoefficients],
        candidateParams: [(frequency: Double, q: Double)],
        frequencies: [Double],
        sampleRate: Double
    ) -> Double {
        var groupDelay = [Double](repeating: 0, count: frequencies.count)
        for section in biquadSections {
            for (i, f) in frequencies.enumerated() {
                groupDelay[i] += groupDelayAtFrequency(biquad: section, frequency: f, sampleRate: sampleRate)
            }
        }
        for (freq, q) in candidateParams {
            let ap = allPassSectionFromParams(frequency: freq, q: q, sampleRate: sampleRate)
            for (i, f) in frequencies.enumerated() {
                groupDelay[i] += groupDelayAtFrequency(allPass: ap, frequency: f, sampleRate: sampleRate)
            }
        }
        return peakGroupDelayDeviation(groupDelay: groupDelay)
    }

    /// Fits optimized all-pass sections for a single band using numerical optimization.
    ///
    /// - Parameters:
    ///   - biquadSections: The biquad sections for this band.
    ///   - sampleRate: Audio sample rate in Hz.
    /// - Returns: Array of fitted (frequency, Q) parameters, or nil if fitting fails.
    public static func fitAllPassSectionsForBand(biquadSections: [BiquadCoefficients], sampleRate: Double) -> [FittedAllPassParams]? {
        // Generate cache key from biquad coefficients and sample rate
        let cacheKey = biquadSections.map { "\($0.b0),\($0.b1),\($0.b2),\($0.a1),\($0.a2)" }.joined(separator: "|") + "|sr:\(sampleRate)"

        // Check cache
        cacheLock.lock()
        if let cached = fittedSectionsCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Fit N sections using multi-start coordinate search
        let fittedParams = fitAllPassSectionsWithCoordinateSearch(
            biquadSections: biquadSections,
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

    /// Fits optimized all-pass sections for the entire active chain using numerical optimization.
    ///
    /// - Parameters:
    ///   - biquadSections: All biquad sections across all active bands.
    ///   - bandFrequencyHints: Estimated center frequencies for each band.
    ///   - sampleRate: Audio sample rate in Hz.
    ///   - numSections: Number of all-pass sections to fit.
    /// - Returns: Array of fitted (frequency, Q) parameters, or nil if fitting fails.
    public static func fitAllPassSectionsForChain(
        biquadSections: [BiquadCoefficients],
        bandFrequencyHints: [Double],
        sampleRate: Double,
        numSections: Int
    ) -> [FittedAllPassParams]? {
        // Generate cache key from all biquad coefficients and sample rate
        let cacheKey = biquadSections.map { "\($0.b0),\($0.b1),\($0.b2),\($0.a1),\($0.a2)" }.joined(separator: "|") + "|sr:\(sampleRate)"

        // Check cache
        cacheLock.lock()
        if let cached = fittedSectionsCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Fit N sections using multi-start coordinate search with multi-band seeding
        let fittedParams = fitAllPassSectionsWithCoordinateSearchForChain(
            biquadSections: biquadSections,
            bandFrequencyHints: bandFrequencyHints,
            sampleRate: sampleRate,
            numSections: numSections
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

    /// Fits all-pass sections using multi-start coordinate search with peak group delay deviation objective.
    private static func fitAllPassSectionsWithCoordinateSearch(
        biquadSections: [BiquadCoefficients],
        sampleRate: Double,
        numSections: Int
    ) -> [FittedAllPassParams]? {
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)

        // Compute baseline peak deviation for biquad chain alone
        let gdBiquad = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: [], frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationBiquad = peakGroupDelayDeviation(groupDelay: gdBiquad)

        // Generate deterministic multi-start configurations
        let seedMultipliers: [Double] = [0.5, 1.0, 2.0]
        let seedQs: [Double] = [0.7, 2.0, 6.0]

        // Estimate band frequency from biquad sections (use geometric mean of center frequencies)
        let bandFrequency = estimateBandFrequency(biquadSections: biquadSections, sampleRate: sampleRate)

        var candidateStarts: [[(frequency: Double, q: Double)]] = []
        for freqMult in seedMultipliers {
            for q in seedQs {
                let seedFreq = max(20.0, min(bandFrequency * freqMult, sampleRate * 0.4))
                candidateStarts.append(Array(repeating: (frequency: seedFreq, q: q), count: numSections))
            }
        }

        // Run coordinate search from each starting point and keep the best result
        var bestParams: [FittedAllPassParams]?
        var bestDeviation = peakDeviationBiquad  // Initialize with baseline (no correction)

        for startConfig in candidateStarts {
            let params = runCoordinateSearch(
                biquadSections: biquadSections,
                startParams: startConfig,
                frequencies: frequencies,
                sampleRate: sampleRate,
                numSections: numSections
            )

            if let params = params {
                let candidateParams = params.map { (frequency: $0.frequency, q: $0.q) }
                let deviation = evaluateCandidate(
                    biquadSections: biquadSections,
                    candidateParams: candidateParams,
                    frequencies: frequencies,
                    sampleRate: sampleRate
                )

                if deviation < bestDeviation {
                    bestDeviation = deviation
                    bestParams = params
                }
            }
        }

        // Only return if improvement is significant (> 5%)
        if let bestParams = bestParams, bestDeviation < peakDeviationBiquad * 0.95 {
            return bestParams
        }

        return nil  // Fitting didn't improve enough
    }

    /// Fits all-pass sections for the entire chain using multi-start coordinate search with multi-band seeding.
    private static func fitAllPassSectionsWithCoordinateSearchForChain(
        biquadSections: [BiquadCoefficients],
        bandFrequencyHints: [Double],
        sampleRate: Double,
        numSections: Int
    ) -> [FittedAllPassParams]? {
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)

        // Compute baseline peak deviation for biquad chain alone
        let gdBiquad = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: [], frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationBiquad = peakGroupDelayDeviation(groupDelay: gdBiquad)

        // Generate deterministic multi-start configurations seeded around EVERY active band's frequency
        let seedMultipliers: [Double] = [0.5, 1.0, 2.0]
        let seedQs: [Double] = [0.7, 2.0, 6.0]

        var candidateStarts: [[(frequency: Double, q: Double)]] = []
        for bandFreq in bandFrequencyHints {
            for freqMult in seedMultipliers {
                for q in seedQs {
                    let seedFreq = max(20.0, min(bandFreq * freqMult, sampleRate * 0.4))
                    candidateStarts.append(Array(repeating: (frequency: seedFreq, q: q), count: numSections))
                }
            }
        }

        // Run coordinate search from each starting point and keep the best result
        var bestParams: [FittedAllPassParams]?
        var bestDeviation = peakDeviationBiquad  // Initialize with baseline (no correction)

        for startConfig in candidateStarts {
            let params = runCoordinateSearch(
                biquadSections: biquadSections,
                startParams: startConfig,
                frequencies: frequencies,
                sampleRate: sampleRate,
                numSections: numSections
            )

            if let params = params {
                let candidateParams = params.map { (frequency: $0.frequency, q: $0.q) }
                let deviation = evaluateCandidate(
                    biquadSections: biquadSections,
                    candidateParams: candidateParams,
                    frequencies: frequencies,
                    sampleRate: sampleRate
                )

                if deviation < bestDeviation {
                    bestDeviation = deviation
                    bestParams = params
                }
            }
        }

        // Only return if improvement is significant (> 5%)
        if let bestParams = bestParams, bestDeviation < peakDeviationBiquad * 0.95 {
            return bestParams
        }

        return nil  // Fitting didn't improve enough
    }

    /// Estimates the center frequency of a biquad band.
    public static func estimateBandFrequency(biquadSections: [BiquadCoefficients], sampleRate: Double) -> Double {
        // For a peaking EQ biquad, the center frequency can be estimated from the coefficients
        // This is a simplified estimate - we use the geometric mean of estimated frequencies
        var frequencies: [Double] = []
        for sec in biquadSections {
            // Estimate from the denominator: a1 = -2*cos(ω0)/Q, a2 = 1/Q^2 for peaking EQ
            // This is approximate but works for our purpose of seeding the search
            let omega0 = acos(-sec.a1 / (2 * sqrt(sec.a2)))
            let freq = omega0 * sampleRate / (2 * .pi)
            if freq > 20 && freq < sampleRate * 0.4 {
                frequencies.append(freq)
            }
        }

        if frequencies.isEmpty {
            return 1000.0  // Fallback to 1 kHz if estimation fails
        }

        // Return geometric mean
        let logSum = frequencies.map { log($0) }.reduce(0, +)
        return exp(logSum / Double(frequencies.count))
    }

    /// Runs coordinate search from a given starting point.
    private static func runCoordinateSearch(
        biquadSections: [BiquadCoefficients],
        startParams: [(frequency: Double, q: Double)],
        frequencies: [Double],
        sampleRate: Double,
        numSections: Int
    ) -> [FittedAllPassParams]? {
        var params = startParams.map { FittedAllPassParams(frequency: $0.frequency, q: $0.q) }

        let iterations = 50

        for _ in 0..<iterations {
            var improved = false

            for i in 0..<numSections {
                // Optimize frequency
                let originalFreq = params[i].frequency
                let bestFreq = optimizeParameter(
                    params: params,
                    paramIndex: i,
                    isFrequency: true,
                    biquadSections: biquadSections,
                    frequencies: frequencies,
                    sampleRate: sampleRate,
                    originalValue: originalFreq
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
                    biquadSections: biquadSections,
                    frequencies: frequencies,
                    sampleRate: sampleRate,
                    originalValue: originalQ
                )

                if bestQ != originalQ {
                    params[i].q = max(0.1, bestQ)
                    improved = true
                }
            }

            if !improved {
                break
            }
        }

        return params
    }

    /// Optimizes a single parameter using coordinate search with peak group delay deviation objective.
    private static func optimizeParameter(
        params: [FittedAllPassParams],
        paramIndex: Int,
        isFrequency: Bool,
        biquadSections: [BiquadCoefficients],
        frequencies: [Double],
        sampleRate: Double,
        originalValue: Double
    ) -> Double {
        let testValues = [
            originalValue * 0.8,
            originalValue * 0.9,
            originalValue,
            originalValue * 1.1,
            originalValue * 1.2
        ]

        var bestValue = originalValue
        var bestDeviation = Double.infinity

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

            let candidateParams = testParams.map { (frequency: $0.frequency, q: $0.q) }
            let deviation = evaluateCandidate(
                biquadSections: biquadSections,
                candidateParams: candidateParams,
                frequencies: frequencies,
                sampleRate: sampleRate
            )

            if deviation < bestDeviation {
                bestDeviation = deviation
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

    /// Evaluates whether cascading multiple all-pass sections with a biquad chain
    /// measurably improves group delay (reduces peak deviation from median).
    ///
    /// - Parameters:
    ///   - biquadSections: All biquad sections across the active chain.
    ///   - allPassSections: The candidate all-pass sections to test.
    ///   - sampleRate: Audio sample rate in Hz.
    /// - Returns: true if the all-pass sections improve group delay, false otherwise.
    private static func allPassSectionsImproveGroupDelayForChain(
        biquadSections: [BiquadCoefficients],
        allPassSections: [AllPassSection],
        sampleRate: Double
    ) -> Bool {
        let frequencies = logSpacedFrequencies(minFreq: 20.0, maxFreq: 20000.0, count: 200)

        // Compute group delay of biquad chain alone
        let gdBiquad = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: [], frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationBiquad = peakGroupDelayDeviation(groupDelay: gdBiquad)

        // Compute group delay of biquad chain + all-pass sections
        let gdCombined = computeGroupDelayForChain(biquadSections: biquadSections, allPassSections: allPassSections, frequencies: frequencies, sampleRate: sampleRate)
        let peakDeviationCombined = peakGroupDelayDeviation(groupDelay: gdCombined)

        // Only accept the all-pass sections if they reduce peak deviation
        return peakDeviationCombined < peakDeviationBiquad * 0.95  // Require 5% improvement
    }

    /// Clears processing state (call when mode is disabled).
    func reset() {
        for i in 0..<activeCount {
            activeStore[i].w1 = 0
            activeStore[i].w2 = 0
        }
    }
}
