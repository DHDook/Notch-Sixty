// TargetCurveLibrary.swift
// Built-in reference target curves for room correction.
// All curves expressed as (frequency Hz, gain dB) pairs, log-spaced.
// Reference: Harman International listening research (Olive et al. 2013).

import Foundation

enum TargetCurveLibrary {

    /// Flat 0 dB reference. Use when no preference is set.
    static let flat: [(frequency: Double, gainDB: Double)] = [
        (20, 0), (20_000, 0)
    ]

    /// Harman over-ear target. Shelved bass rise, flat midrange, gentle treble fall.
    /// Suitable as a room correction target for in-room speaker measurements.
    static let harmanRoom: [(frequency: Double, gainDB: Double)] = [
        (20, 6.5), (40, 5.0), (63, 4.0), (80, 3.5), (100, 3.0), (125, 2.5),
        (160, 2.0), (200, 1.5), (250, 1.0), (315, 0.5), (400, 0.0), (500, 0.0),
        (630, 0.0), (800, 0.0), (1000, 0.0), (1250, -0.3), (1600, -0.5),
        (2000, -0.8), (2500, -1.0), (3150, -1.5), (4000, -2.0), (5000, -2.5),
        (6300, -3.0), (8000, -3.5), (10000, -4.0), (12500, -4.5), (16000, -5.0),
        (20000, -6.0)
    ]

    /// B&K house curve: 3 dB/octave bass rise below 1 kHz.
    /// Commonly used in professional recording studio calibration.
    static let bkHouse: [(frequency: Double, gainDB: Double)] = [
        (20, 9.0), (63, 7.0), (200, 4.5), (630, 1.5), (1000, 0.0),
        (2000, 0.0), (5000, 0.0), (10000, 0.0), (20000, 0.0)
    ]

    /// Gentle home cinema shelf: slight bass warmth, slight air-band lift.
    static let homeTheater: [(frequency: Double, gainDB: Double)] = [
        (20, 3.0), (40, 2.5), (80, 2.0), (160, 1.0), (400, 0.0), (1000, 0.0),
        (4000, 0.0), (8000, 0.5), (12000, 1.0), (16000, 1.5), (20000, 2.0)
    ]

    static let allCurves: [(name: String, curve: [(frequency: Double, gainDB: Double)])] = [
        ("Flat",         flat),
        ("Harman room",  harmanRoom),
        ("B&K house",    bkHouse),
        ("Home theater", homeTheater)
    ]
}
