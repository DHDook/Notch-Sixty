// AudioConstants.swift
// Centralized constants for audio pipeline configuration

import Foundation

/// Constants for audio rendering pipeline configuration.
///
/// These values were chosen based on:
/// - Real-time safety requirements
/// - Memory constraints
/// - Latency vs. stability tradeoffs
enum AudioConstants {
    // MARK: - Render Pipeline
    
    /// Maximum frames per render callback.
    ///
    /// This is the worst-case frame count that CoreAudio may request.
    /// Setting this too low causes buffer overflows on high sample rates.
    /// Setting too high wastes memory.
    ///
    /// - 16384 frames = ~341ms at 48kHz, ~170ms at 96kHz, ~21ms at 768kHz
    /// - Matches driver's kDevice_RingBufferSize (16384) for 768kHz support
    static let maxFrameCount: UInt32 = 16384
    
    /// Ring buffer capacity in sample frames per channel.
    ///
    /// Must be a power of 2 for efficient modulo arithmetic.
    /// Larger values provide more resilience against clock drift but increase latency.
    ///
    /// - 32768 samples = ~682ms at 48kHz, ~341ms at 96kHz, ~43ms at 768kHz
    /// - Chosen to handle reasonable clock drift between devices at all supported rates
    static let ringBufferCapacity: Int = 32768
    
    // MARK: - EQ Band Limits

    /// Minimum allowed EQ frequency in Hz.
    static let minEQFrequency: Float = 1

    /// Returns the maximum allowed EQ frequency in Hz for a given sample rate.
    ///
    /// The upper bound scales with sample rate to allow filters above 22 kHz at
    /// high sample rates (e.g. tweeter breakup notches at 96+ kHz operation),
    /// while preserving 22 kHz as the minimum ceiling so standard-rate behaviour
    /// is unchanged.
    ///
    /// Formula: max(22_000, min(sampleRate × 0.45, 96_000))
    ///
    /// Representative values:
    ///   44.1 kHz → 22 000 Hz   (standard, unchanged)
    ///    48 kHz  → 22 000 Hz   (standard, unchanged)
    ///  88.2 kHz  → 39 690 Hz
    ///    96 kHz  → 43 200 Hz
    ///   192 kHz  → 86 400 Hz
    ///   384 kHz  → 96 000 Hz   (capped)
    ///   768 kHz  → 96 000 Hz   (capped)
    ///
    /// Cross-rate preset compatibility: band frequencies are stored as absolute
    /// Hz values. `clampFrequency(_:at:)` is applied at load time, so a band at
    /// 35 kHz saved at 96 kHz will be clamped to 22 kHz when loaded at 48 kHz.
    static func maxEQFrequency(at sampleRate: Float) -> Float {
        let nyquistBound = sampleRate * 0.45
        let capped       = min(nyquistBound, 96_000)
        return max(22_000, capped)
    }

    /// Minimum gain in dB for EQ bands.
    static let minGain: Float = -36

    /// Maximum gain in dB for EQ bands.
    static let maxGain: Float = 36

    // MARK: - Computed Properties

    /// Valid gain range for EQ band sliders.
    static var gainRange: ClosedRange<Float> { minGain...maxGain }

    // MARK: - Validation Helpers

    /// Clamps frequency to the valid EQ range for the given sample rate.
    ///
    /// Use this overload when the current sample rate is known (preferred).
    static func clampFrequency(_ value: Float, at sampleRate: Float) -> Float {
        max(minEQFrequency, min(maxEQFrequency(at: sampleRate), value))
    }

    /// Clamps frequency to the valid EQ range, assuming 48 kHz.
    ///
    /// Use only in contexts where the sample rate is unavailable (e.g. preset
    /// decoding before a pipeline is running). Prefer `clampFrequency(_:at:)`
    /// in the UI and audio pipeline.
    static func clampFrequency(_ value: Float) -> Float {
        clampFrequency(value, at: 48_000)
    }

    /// Clamps gain to valid EQ range.
    static func clampGain(_ value: Float) -> Float {
        max(minGain, min(maxGain, value))
    }
}