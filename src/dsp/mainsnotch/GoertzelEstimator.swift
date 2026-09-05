import Foundation

enum GoertzelEstimator {

    /// Evaluates signal power at a single arbitrary target frequency
    /// (not restricted to FFT bin frequencies) via the standard Goertzel
    /// recursion. O(N) per call, N = buffer.count.
    static func power(buffer: [Float], sampleRate: Double, targetHz: Double) -> Float {
        let omega = 2.0 * Double.pi * targetHz / sampleRate
        let coeff = 2.0 * cos(omega)
        var sPrev = 0.0
        var sPrev2 = 0.0
        for x in buffer {
            let s = Double(x) + coeff * sPrev - sPrev2
            sPrev2 = sPrev
            sPrev = s
        }
        let real = sPrev - sPrev2 * cos(omega)
        let imag = sPrev2 * sin(omega)
        return Float(real * real + imag * imag)
    }

    /// Scans [lowHz, highHz] in `stepHz` increments, finds the strongest
    /// candidate, and refines it via parabolic interpolation using the
    /// neighboring two scan points for sub-step precision. Returns nil if
    /// the buffer is too short to evaluate the range meaningfully.
    /// - Returns: (frequencyHz, peakPower, confidenceDB) where confidenceDB
    ///   is the peak's power relative to a reference point well clear of
    /// the peak (3 steps away) — use this to gate whether a measurement
    /// should be trusted (see MainsHumDetector).
    static func scanForPeak(
        buffer: [Float], sampleRate: Double,
        lowHz: Double, highHz: Double, stepHz: Double
    ) -> (frequencyHz: Double, peakPower: Float, confidenceDB: Float)? {
        guard highHz > lowHz, stepHz > 0 else { return nil }
        let steps = Int((highHz - lowHz) / stepHz)
        guard steps >= 4 else { return nil }

        var powers = [Float](repeating: 0, count: steps + 1)
        for i in 0...steps {
            let f = lowHz + Double(i) * stepHz
            powers[i] = power(buffer: buffer, sampleRate: sampleRate, targetHz: f)
        }

        var peakIdx = 0
        for i in 1...steps where powers[i] > powers[peakIdx] { peakIdx = i }

        // Parabolic interpolation using neighbors, when available.
        var refinedHz = lowHz + Double(peakIdx) * stepHz
        if peakIdx > 0 && peakIdx < steps {
            let y1 = Double(powers[peakIdx - 1])
            let y2 = Double(powers[peakIdx])
            let y3 = Double(powers[peakIdx + 1])
            let denom = y1 - 2.0 * y2 + y3
            if abs(denom) > 1e-12 {
                let d = (y1 - y3) / (2.0 * denom)
                refinedHz += d.clamped(to: -1.0...1.0) * stepHz
            }
        }

        // Reference point 3 steps away from the peak (clamped into range)
        // for a confidence estimate — how far above the local floor is
        // this peak?
        let refIdx = (peakIdx + 3 <= steps) ? peakIdx + 3 : max(0, peakIdx - 3)
        let refPower = max(powers[refIdx], 1e-12)
        let peakPower = max(powers[peakIdx], 1e-12)
        let confidenceDB = 10.0 * log10(Double(peakPower) / Double(refPower))

        return (refinedHz, powers[peakIdx], Float(confidenceDB))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
