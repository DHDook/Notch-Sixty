import Foundation

/// Pure functions for audio math conversions.
/// All functions are real-time safe: no allocations, no locks, no side effects.
enum AudioMath {
    /// Converts decibels to linear amplitude.
    /// - Parameter db: dBFS value.
    /// - Returns: Linear amplitude (10^(db/20)).
    @inline(__always)
    static func dbToLinear(_ db: Float) -> Float {
        powf(10.0, db / 20.0)
    }

    /// Converts linear amplitude to decibels.
    /// - Parameters:
    ///   - linear: Linear amplitude.
    ///   - silence: The silence floor value to return for very low inputs (default: -90).
    /// - Returns: dBFS value.
    @inline(__always)
    static func linearToDB(_ linear: Float, silence: Float = -90) -> Float {
        guard linear > 1e-7 else { return silence }
        return max(silence, 20 * log10(linear))
    }

    /// Generates logarithmically spaced frequencies between two bounds.
    /// - Parameters:
    ///   - from: Starting frequency in Hz.
    ///   - to: Ending frequency in Hz.
    ///   - count: Number of frequency points to generate.
    /// - Returns: Array of logarithmically spaced frequencies.
    static func logSpacedFrequencies(from: Double, to: Double, count: Int) -> [Double] {
        guard count > 1 else { return [from] }
        var frequencies: [Double] = []
        let logFrom = log(from)
        let logTo = log(to)
        let step = (logTo - logFrom) / Double(count - 1)

        for i in 0..<count {
            frequencies.append(exp(logFrom + Double(i) * step))
        }

        return frequencies
    }
}