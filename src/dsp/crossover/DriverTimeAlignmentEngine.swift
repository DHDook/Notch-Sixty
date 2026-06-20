// DriverTimeAlignmentEngine.swift
//
// Automatic driver time alignment and polarity detection from impulse response measurements.
// Extracts acoustic arrival times and computes delay corrections to time-align all drivers
// at the listening position. Also detects absolute polarity from impulse response peaks.

import Foundation

enum DriverTimeAlignmentEngine {

    struct TimeAlignmentResult: Sendable {
        /// Suggested delay per channel index (ms). Zero for the reference channel.
        var delayPerChannel: [Int: Float]
        /// The channel index chosen as the time reference (zero delay).
        /// Always the channel whose driver arrives LATEST at the microphone
        /// (largest arrival time = greatest physical distance from the listening position).
        /// All other channels are delayed to match it.
        var referenceChannelIndex: Int
        /// Arrival time of each channel's direct sound at the microphone (ms from sweep start).
        var arrivalTimesMs: [Int: Float]
        /// Human-readable summary for display.
        var summary: String
    }

    enum PolarityResult: Sendable {
        case correct     // IR peak is positive — standard wiring
        case inverted    // IR peak is negative — driver or amplifier wired in reverse
        case uncertain   // Peak magnitude too low to determine reliably (SNR < threshold)
    }

    /// Computes time alignment delays from a set of measured impulse responses.
    ///
    /// Algorithm:
    ///   1. For each measured channel, find the peak of the impulse response
    ///      within a search window of 0–50 ms (direct sound region).
    ///      Peak detection: maximum of the absolute value (handles inverted polarity).
    ///   2. Convert peak sample index to time in ms: arrivalMs = peakSample / sampleRate × 1000
    ///   3. Reference channel: the one with the LARGEST arrivalMs
    ///      (furthest acoustic distance from the microphone).
    ///   4. For each other channel:
    ///      delayMs = referencArrivalMs − channelArrivalMs
    ///      This is always ≥ 0 (we add delay to the closer drivers to match the farthest).
    ///   5. Clamp all delays to [0, OutputChannelConfig.maxDelayMs].
    ///
    /// - Parameters:
    ///   - measurements: Keyed by channel index. Must include at least 2 channels.
    ///   - sampleRate: Sample rate of the impulse responses.
    ///   - searchWindowMs: Time window to search for the direct sound peak.
    ///     Default: 50 ms. Must be < IR duration.
    /// - Returns: TimeAlignmentResult with per-channel delays.
    static func computeAlignment(
        measurements: [Int: ChannelTransferFunctionData],
        sampleRate: Double,
        searchWindowMs: Double = 50.0
    ) -> TimeAlignmentResult {
        guard measurements.count >= 2 else {
            return TimeAlignmentResult(
                delayPerChannel: [:],
                referenceChannelIndex: -1,
                arrivalTimesMs: [:],
                summary: "Insufficient measurements (need at least 2 channels)"
            )
        }

        var arrivalTimesMs: [Int: Float] = [:]
        var maxArrivalMs: Float = 0
        var referenceChannelIndex: Int = -1

        // Step 1 & 2: Find peak and compute arrival time for each channel
        for (channelIndex, data) in measurements {
            guard let ir = data.averagedIR else { continue }

            let searchWindowSamples = Int(searchWindowMs * sampleRate / 1000.0)
            let searchEnd = min(ir.count, searchWindowSamples)

            // Find peak within search window
            var maxSample: Float = 0
            var peakIdx = 0
            for i in 0..<searchEnd {
                if abs(ir[i]) > maxSample {
                    maxSample = abs(ir[i])
                    peakIdx = i
                }
            }

            // Convert to ms
            let arrivalMs = Float(peakIdx) / Float(sampleRate) * 1000.0
            arrivalTimesMs[channelIndex] = arrivalMs

            // Track reference (latest arrival)
            if arrivalMs > maxArrivalMs {
                maxArrivalMs = arrivalMs
                referenceChannelIndex = channelIndex
            }
        }

        // Step 3 & 4: Compute delays relative to reference
        var delayPerChannel: [Int: Float] = [:]
        let maxDelayMs: Float = 100.0  // OutputChannelConfig.maxDelayMs

        for (channelIndex, arrivalMs) in arrivalTimesMs {
            let delayMs = maxArrivalMs - arrivalMs
            let clampedDelay = min(max(0, delayMs), maxDelayMs)
            delayPerChannel[channelIndex] = clampedDelay
        }

        // Build summary
        var summaryLines: [String] = []
        summaryLines.append("Reference channel: \(referenceChannelIndex) (latest arrival)")
        for (channelIndex, delayMs) in delayPerChannel.sorted(by: { $0.key < $1.key }) {
            let arrival = arrivalTimesMs[channelIndex] ?? 0
            summaryLines.append("Channel \(channelIndex): arrival \(arrival) ms, delay \(delayMs) ms")
        }

        return TimeAlignmentResult(
            delayPerChannel: delayPerChannel,
            referenceChannelIndex: referenceChannelIndex,
            arrivalTimesMs: arrivalTimesMs,
            summary: summaryLines.joined(separator: "\n")
        )
    }

    /// Detects the absolute polarity of a measured impulse response.
    ///
    /// Algorithm:
    ///   1. Find the direct sound peak within the search window (as in computeAlignment).
    ///   2. Check the sign of the peak sample (not the absolute value).
    ///      Positive peak → correct polarity.
    ///      Negative peak → inverted polarity.
    ///   3. Uncertainty check: if |peak| < noiseFloor × snrThreshold, return .uncertain.
    ///
    /// Note: This detects electrical polarity (wiring), not acoustic polarity.
    /// Acoustic polarity may be deliberately inverted by some crossover designs
    /// (e.g. second-order Butterworth with a 180° polarity flip on one driver).
    /// The UI must inform the user of this distinction.
    ///
    /// - Parameters:
    ///   - ir: Measured impulse response.
    ///   - sampleRate: Sample rate.
    ///   - searchWindowMs: Time window for direct sound. Default: 50 ms.
    ///   - snrThresholdDB: Minimum SNR to return .correct or .inverted. Default: 20 dB.
    static func detectPolarity(
        ir: [Float],
        sampleRate: Double,
        searchWindowMs: Double = 50.0,
        snrThresholdDB: Double = 20.0
    ) -> PolarityResult {
        guard !ir.isEmpty else { return .uncertain }

        let searchWindowSamples = Int(searchWindowMs * sampleRate / 1000.0)
        let searchEnd = min(ir.count, searchWindowSamples)

        // Find peak within search window
        var maxSample: Float = 0
        var peakIdx = 0
        for i in 0..<searchEnd {
            if abs(ir[i]) > maxSample {
                maxSample = abs(ir[i])
                peakIdx = i
            }
        }

        // Check SNR
        let snr = RoomCorrectionEngine.estimateSNR(ir: ir, sampleRate: sampleRate)
        guard snr >= snrThresholdDB else {
            return .uncertain
        }

        // Check polarity (sign of the peak sample, not absolute)
        let peakValue = ir[peakIdx]
        if peakValue > 0 {
            return .correct
        } else if peakValue < 0 {
            return .inverted
        } else {
            return .uncertain
        }
    }

    // MARK: - Acoustic Centre Calibration (Part 2 Task AF)

    /// Computes time alignment using group delay at the crossover frequency
    /// rather than the broadband IR peak.
    ///
    /// This produces more accurate alignment at the crossover point at the cost
    /// of being specific to one crossover frequency — it is most useful for
    /// the final fine-tuning step after broadband alignment (Task V) is complete.
    ///
    /// Algorithm:
    ///   1. For each measured channel, compute the group delay at the relevant
    ///      crossover frequency using:
    ///      τ(f) = −d/dω [arg(H(e^jω))] evaluated at ω = 2π × crossoverHz / sampleRate
    ///      where H(e^jω) is the complex frequency response from the measurement.
    ///   2. The reference channel is the one with the largest group delay at the
    ///      crossover frequency (most delayed at that frequency).
    ///   3. Alignment delay for each channel:
    ///      delayMs = (referenceGroupDelayMs − channelGroupDelayMs)
    ///      Added on top of the existing broadband alignment delay (from Task V).
    ///      The result replaces the existing delayMs in OutputChannelConfig.
    ///
    /// - Parameters:
    ///   - measurements: Per-channel complex frequency responses from TransferFunctionDataset.
    ///   - crossoverHz: The crossover frequency at which to align.
    ///   - sampleRate: System sample rate.
    ///   - existingDelaysMs: Current broadband alignment delays (from Task V / computeAlignment).
    ///     These are replaced, not added to, by the acoustic centre correction.
    /// - Returns: TimeAlignmentResult with refined delays.
    static func computeAcousticCentreAlignment(
        measurements: [Int: ChannelTransferFunctionData],
        crossoverHz: Double,
        sampleRate: Double,
        existingDelaysMs: [Int: Float]
    ) -> TimeAlignmentResult {
        guard measurements.count >= 2 else {
            return TimeAlignmentResult(
                delayPerChannel: [:],
                referenceChannelIndex: -1,
                arrivalTimesMs: [:],
                summary: "Insufficient measurements (need at least 2 channels)"
            )
        }

        var groupDelaysMs: [Int: Float] = [:]
        var maxGroupDelayMs: Float = 0
        var referenceChannelIndex: Int = -1

        // Step 1: Compute group delay at crossover frequency for each channel
        for (channelIndex, data) in measurements {
            guard let complexResponse = data.averagedComplexResponse, !complexResponse.isEmpty else { continue }

            // Find the frequency bin closest to crossover frequency
            let targetFreq = crossoverHz
            let closestIndex = complexResponse.enumerated().min(by: { (lhs, rhs) in
                abs(lhs.element.frequency - targetFreq) < abs(rhs.element.frequency - targetFreq)
            })?.offset

            guard let idx = closestIndex else { continue }

            // Compute group delay using finite difference of phase
            // Group delay τ(f) = -dφ/dω where φ is phase in radians, ω is angular frequency
            // We approximate dφ/dω using central difference: (φ(f+Δf) - φ(f-Δf)) / (2πΔf)
            let deltaIdx = 1
            if idx > deltaIdx && idx < complexResponse.count - deltaIdx {
                let freqPlus = complexResponse[idx + deltaIdx].frequency
                let freqMinus = complexResponse[idx - deltaIdx].frequency
                let phasePlus = atan2(Float(complexResponse[idx + deltaIdx].imag), Float(complexResponse[idx + deltaIdx].real))
                let phaseMinus = atan2(Float(complexResponse[idx - deltaIdx].imag), Float(complexResponse[idx - deltaIdx].real))

                // Unwrap phase to avoid 2π jumps
                var phaseDiff = phasePlus - phaseMinus
                while phaseDiff > Float.pi { phaseDiff -= 2 * Float.pi }
                while phaseDiff < -Float.pi { phaseDiff += 2 * Float.pi }

                let deltaFreq = freqPlus - freqMinus
                guard deltaFreq > 0 else { continue }

                // Group delay in seconds: -dφ/dω = -dφ/(2πdf)
                let groupDelaySeconds = -phaseDiff / (2 * Float.pi * Float(deltaFreq))
                let groupDelayMs = groupDelaySeconds * 1000.0

                groupDelaysMs[channelIndex] = groupDelayMs

                // Track reference (largest group delay)
                if groupDelayMs > maxGroupDelayMs {
                    maxGroupDelayMs = groupDelayMs
                    referenceChannelIndex = channelIndex
                }
            }
        }

        // Step 2 & 3: Compute refined delays relative to reference
        var delayPerChannel: [Int: Float] = [:]
        let maxDelayMs: Float = 100.0  // OutputChannelConfig.maxDelayMs

        for (channelIndex, groupDelayMs) in groupDelaysMs {
            let delayMs = maxGroupDelayMs - groupDelayMs
            let clampedDelay = min(max(0, delayMs), maxDelayMs)
            delayPerChannel[channelIndex] = clampedDelay
        }

        // Build summary
        var summaryLines: [String] = []
        summaryLines.append("Acoustic centre refinement at \(Int(crossoverHz)) Hz")
        summaryLines.append("Reference channel: \(referenceChannelIndex) (largest group delay)")
        for (channelIndex, delayMs) in delayPerChannel.sorted(by: { $0.key < $1.key }) {
            let groupDelay = groupDelaysMs[channelIndex] ?? 0
            summaryLines.append("Channel \(channelIndex): group delay \(groupDelay) ms, refined delay \(delayMs) ms")
        }

        return TimeAlignmentResult(
            delayPerChannel: delayPerChannel,
            referenceChannelIndex: referenceChannelIndex,
            arrivalTimesMs: groupDelaysMs,  // Use group delays as "arrival times" for this context
            summary: summaryLines.joined(separator: "\n")
        )
    }
}
