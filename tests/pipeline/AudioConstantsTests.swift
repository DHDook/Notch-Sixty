// AudioConstantsTests.swift
// Tests for AudioConstants EQ frequency bounds.

import XCTest
@testable import Equaliser

final class AudioConstantsTests: XCTestCase {

    // MARK: - maxEQFrequency(at:) — standard rates unchanged

    func testMaxEQFrequency_44100_Returns22000() {
        XCTAssertEqual(AudioConstants.maxEQFrequency(at: 44100), 22_000,
            "At 44.1 kHz, max EQ frequency must remain 22 000 Hz for backward compatibility")
    }

    func testMaxEQFrequency_48000_Returns22000() {
        XCTAssertEqual(AudioConstants.maxEQFrequency(at: 48000), 22_000,
            "At 48 kHz, max EQ frequency must remain 22 000 Hz for backward compatibility")
    }

    // MARK: - maxEQFrequency(at:) — high rates scale up

    func testMaxEQFrequency_88200_ScalesUp() {
        let result = AudioConstants.maxEQFrequency(at: 88200)
        XCTAssertGreaterThan(result, 22_000,
            "At 88.2 kHz, max EQ frequency should exceed 22 000 Hz")
        XCTAssertEqual(result, 88200 * 0.45, accuracy: 1.0,
            "At 88.2 kHz, max EQ frequency should be fs × 0.45")
    }

    func testMaxEQFrequency_96000_Returns43200() {
        let result = AudioConstants.maxEQFrequency(at: 96000)
        XCTAssertEqual(result, 43_200, accuracy: 1.0,
            "At 96 kHz, max EQ frequency should be 96000 × 0.45 = 43 200 Hz")
    }

    func testMaxEQFrequency_192000_Returns86400() {
        let result = AudioConstants.maxEQFrequency(at: 192000)
        XCTAssertEqual(result, 86_400, accuracy: 1.0,
            "At 192 kHz, max EQ frequency should be 192000 × 0.45 = 86 400 Hz")
    }

    // MARK: - maxEQFrequency(at:) — cap at 96 kHz

    func testMaxEQFrequency_384000_CappedAt96000() {
        XCTAssertEqual(AudioConstants.maxEQFrequency(at: 384000), 96_000,
            "At 384 kHz, max EQ frequency must be capped at 96 000 Hz")
    }

    func testMaxEQFrequency_768000_CappedAt96000() {
        XCTAssertEqual(AudioConstants.maxEQFrequency(at: 768000), 96_000,
            "At 768 kHz, max EQ frequency must be capped at 96 000 Hz")
    }

    // MARK: - All driver-supported rates produce a valid bound

    func testMaxEQFrequency_AllSupportedRates_ValidRange() {
        for fs in DRIVER_SUPPORTED_SAMPLE_RATES {
            let maxFreq = AudioConstants.maxEQFrequency(at: Float(fs))
            XCTAssertGreaterThanOrEqual(maxFreq, 22_000,
                "Max EQ frequency at \(fs) Hz must be at least 22 000 Hz; got \(maxFreq)")
            XCTAssertLessThanOrEqual(maxFreq, 96_000,
                "Max EQ frequency at \(fs) Hz must not exceed 96 000 Hz; got \(maxFreq)")
            XCTAssertLessThan(maxFreq, Float(fs) * 0.499,
                "Max EQ frequency at \(fs) Hz must be safely below Nyquist (\(fs * 0.499) Hz); got \(maxFreq)")
        }
    }

    // MARK: - clampFrequency(_:at:)

    func testClampFrequency_WithRate_ClampsToUpperBound() {
        let max96k = AudioConstants.maxEQFrequency(at: 96000)
        let result = AudioConstants.clampFrequency(50_000, at: 96000)
        XCTAssertEqual(result, max96k,
            "clampFrequency(50000, at: 96000) should clamp to \(max96k) Hz")
    }

    func testClampFrequency_WithRate_ClampsToLowerBound() {
        let result = AudioConstants.clampFrequency(-1, at: 48000)
        XCTAssertEqual(result, AudioConstants.minEQFrequency,
            "Frequency below minEQFrequency must be clamped to \(AudioConstants.minEQFrequency) Hz")
    }

    func testClampFrequency_WithRate_PassesThroughValidFrequency() {
        let result = AudioConstants.clampFrequency(1000, at: 48000)
        XCTAssertEqual(result, 1000,
            "A valid frequency (1000 Hz) must pass through clampFrequency unchanged at 48 kHz")
    }

    // MARK: - clampFrequency(_:) — zero-argument overload defaults to 48 kHz

    func testClampFrequency_NoRate_DefaultsTo48kHzBound() {
        // At 48 kHz the max is 22 000 Hz. A value of 25 000 Hz should clamp to 22 000.
        let result = AudioConstants.clampFrequency(25_000)
        XCTAssertEqual(result, AudioConstants.maxEQFrequency(at: 48_000),
            "Zero-argument clampFrequency must default to 48 kHz bound")
    }

    // MARK: - minEQFrequency and gainRange unchanged

    func testMinEQFrequency_IsOne() {
        XCTAssertEqual(AudioConstants.minEQFrequency, 1.0,
            "minEQFrequency must remain 1 Hz")
    }

    func testGainRange_IsUnchanged() {
        XCTAssertEqual(AudioConstants.gainRange, -36.0...36.0,
            "gainRange must remain −36 to +36 dB")
    }
}
