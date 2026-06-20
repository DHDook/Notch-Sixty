import XCTest
@testable import Equaliser

final class DiaphragmResonanceDetectorTests: XCTestCase {

    // MARK: - Test Data Generation

    private func createSyntheticResponse(
        baseLevel: Double = 0.0,
        peaks: [(frequency: Double, prominenceDB: Double, q: Double)] = []
    ) -> [(frequency: Double, gainDB: Double)] {
        var response: [(frequency: Double, gainDB: Double)] = []

        // Generate logarithmic frequency sweep from 20 Hz to 20 kHz
        let startFreq = 20.0
        let endFreq = 20000.0
        let points = 1000
        let logStart = log10(startFreq)
        let logEnd = log10(endFreq)
        let logStep = (logEnd - logStart) / Double(points - 1)

        for i in 0..<points {
            let freq = pow(10.0, logStart + Double(i) * logStep)
            var gain = baseLevel

            // Add peaks
            for peak in peaks {
                let bandwidth = peak.frequency / peak.q
                let lowerFreq = peak.frequency / pow(2.0, bandwidth / peak.frequency / 2.0)
                let upperFreq = peak.frequency * pow(2.0, bandwidth / peak.frequency / 2.0)

                if freq >= lowerFreq && freq <= upperFreq {
                    // Gaussian peak
                    let centre = log10(peak.frequency)
                    let current = log10(freq)
                    let width = log10(upperFreq) - log10(lowerFreq)
                    let normalized = (current - centre) / (width / 2.0)
                    let peakGain = peak.prominenceDB * exp(-normalized * normalized)
                    gain += peakGain
                }
            }

            response.append((frequency: freq, gainDB: gain))
        }

        return response
    }

    // MARK: - Detection Tests

    func testDetectsKnownPeakInSyntheticResponse() {
        // Synthetic response with a Gaussian peak at 3 kHz, 8 dB, Q=10 → candidate detected at ≈3 kHz
        let response = createSyntheticResponse(
            baseLevel: 0.0,
            peaks: [(frequency: 3000.0, prominenceDB: 8.0, q: 10.0)]
        )

        let params = DiaphragmResonanceDetector.DetectionParameters()
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertGreaterThan(candidates.count, 0, "Should detect at least one resonance")

        let detected = candidates[0]
        XCTAssertEqual(detected.frequencyHz, 3000.0, accuracy: 500.0, "Detected frequency should be close to 3 kHz")
        XCTAssertGreaterThan(detected.prominenceDB, 5.0, "Detected prominence should be close to 8 dB")
    }

    func testIgnoresBroadHumpsWithLowQ() {
        // Synthetic shelf-like hump with Q=1 → not returned (below minimumQ)
        let response = createSyntheticResponse(
            baseLevel: 0.0,
            peaks: [(frequency: 1000.0, prominenceDB: 5.0, q: 1.0)]
        )

        let params = DiaphragmResonanceDetector.DetectionParameters()
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertEqual(candidates.count, 0, "Should not detect broad hump with Q < minimumQ")
    }

    func testIgnoresPeaksBelowMinimumProminence() {
        // 2 dB peak with minimumProminenceDB=3 → not returned
        let response = createSyntheticResponse(
            baseLevel: 0.0,
            peaks: [(frequency: 3000.0, prominenceDB: 2.0, q: 10.0)]
        )

        let params = DiaphragmResonanceDetector.DetectionParameters(minimumProminenceDB: 3.0)
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertEqual(candidates.count, 0, "Should not detect peak below minimum prominence")
    }

    func testRanksHighestProminenceFirst() {
        // Two peaks: 8 dB at 3 kHz and 4 dB at 5 kHz → 3 kHz is first
        let response = createSyntheticResponse(
            baseLevel: 0.0,
            peaks: [
                (frequency: 3000.0, prominenceDB: 8.0, q: 10.0),
                (frequency: 5000.0, prominenceDB: 4.0, q: 10.0)
            ]
        )

        let params = DiaphragmResonanceDetector.DetectionParameters()
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertGreaterThan(candidates.count, 1, "Should detect at least two resonances")
        XCTAssertEqual(candidates[0].frequencyHz, 3000.0, accuracy: 500.0, "Highest prominence peak should be first")
    }

    func testMaxCandidatesRespected() {
        // Five peaks detected, maxCandidates=3 → returns exactly 3
        let response = createSyntheticResponse(
            baseLevel: 0.0,
            peaks: [
                (frequency: 1000.0, prominenceDB: 8.0, q: 10.0),
                (frequency: 2000.0, prominenceDB: 7.0, q: 10.0),
                (frequency: 3000.0, prominenceDB: 6.0, q: 10.0),
                (frequency: 4000.0, prominenceDB: 5.0, q: 10.0),
                (frequency: 5000.0, prominenceDB: 4.0, q: 10.0)
            ]
        )

        let params = DiaphragmResonanceDetector.DetectionParameters(maxCandidates: 3)
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertEqual(candidates.count, 3, "Should return exactly maxCandidates")
    }

    func testSuggestedNotchQIsSlightlyNarrowerThanDetected() {
        // Detected Q=12 → suggestedNotch.q ≤ 12 × 0.8 = 9.6
        let response = createSyntheticResponse(
            baseLevel: 0.0,
            peaks: [(frequency: 3000.0, prominenceDB: 8.0, q: 12.0)]
        )

        let params = DiaphragmResonanceDetector.DetectionParameters()
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertGreaterThan(candidates.count, 0, "Should detect at least one resonance")

        let detected = candidates[0]
        let expectedMaxQ = detected.estimatedQ * 0.8
        XCTAssertLessThanOrEqual(detected.suggestedNotch.q, Float(expectedMaxQ), "Suggested Q should be slightly narrower than detected")
    }

    func testFlatResponseProducesNoCandidates() {
        // Flat ±0.5 dB response → empty array returned
        let response = createSyntheticResponse(baseLevel: 0.0, peaks: [])

        let params = DiaphragmResonanceDetector.DetectionParameters()
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertEqual(candidates.count, 0, "Flat response should produce no candidates")
    }

    func testSearchRangeFiltersOutOfBandPeaks() {
        // Peak at 100 Hz, searchRange.low=200 → not returned
        let response = createSyntheticResponse(
            baseLevel: 0.0,
            peaks: [(frequency: 100.0, prominenceDB: 8.0, q: 10.0)]
        )

        let params = DiaphragmResonanceDetector.DetectionParameters(
            searchRangeHz: (low: 200.0, high: 20000.0)
        )
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response, params: params)

        XCTAssertEqual(candidates.count, 0, "Should not detect peak outside search range")
    }
}
