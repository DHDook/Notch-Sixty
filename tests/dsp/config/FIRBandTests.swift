// FIRBandTests.swift
// Tests for FilterType.fir per-band FIR filter implementation.

import XCTest
@testable import Equaliser

final class FIRBandTests: XCTestCase {

    // MARK: - FilterType.fir raw value and coding

    func testFIRFilterTypeRawValue() {
        XCTAssertEqual(FilterType.fir.rawValue, 11,
            "FilterType.fir must have raw value 11 to avoid colliding with legacy migration table")
    }

    func testFIRFilterTypeDisplayName() {
        XCTAssertEqual(FilterType.fir.displayName, "FIR")
        XCTAssertEqual(FilterType.fir.abbreviation, "FIR")
    }

    func testFIRFilterType_InUIOrder() {
        XCTAssertTrue(FilterType.allCasesInUIOrder.contains(.fir),
            ".fir must appear in allCasesInUIOrder")
    }

    func testFIRFilterType_InAllCases() {
        XCTAssertTrue(FilterType.allCases.contains(.fir),
            ".fir must be in allCases (CaseIterable)")
    }

    func testFIRFilterType_ValidatedRawValue() {
        XCTAssertEqual(FilterType(validatedRawValue: 11), .fir,
            "validatedRawValue(11) must produce .fir")
    }

    func testFIRFilterType_ValidatedRawValue_DoesNotCollideWithLegacyMigration() {
        // Legacy migration table uses 7–10; 11 must not be remapped.
        XCTAssertEqual(FilterType(validatedRawValue: 7),  .lowPass)
        XCTAssertEqual(FilterType(validatedRawValue: 8),  .highPass)
        XCTAssertEqual(FilterType(validatedRawValue: 9),  .lowShelf)
        XCTAssertEqual(FilterType(validatedRawValue: 10), .highShelf)
        XCTAssertEqual(FilterType(validatedRawValue: 11), .fir,
            "Raw value 11 must not be remapped by the legacy migration table")
    }

    func testFIRFilterType_EncodeDecode() throws {
        let encoded = try JSONEncoder().encode(FilterType.fir)
        let decoded = try JSONDecoder().decode(FilterType.self, from: encoded)
        XCTAssertEqual(decoded, .fir)
    }

    func testFIRFilterType_FromCodingKey() {
        XCTAssertEqual(FilterType(fromCodingKey: "FIR"), .fir)
    }

    // MARK: - allCases / allCasesInUIOrder counts

    func testAllCasesCount_NowIncludesFIR() {
        XCTAssertEqual(FilterType.allCases.count, 9,
            "allCases must include .fir — expected 9 total filter types")
    }

    func testUIOrderCount_NowIncludesFIR() {
        XCTAssertEqual(FilterType.allCasesInUIOrder.count, 9,
            "allCasesInUIOrder must include .fir — expected 9 total")
    }

    // MARK: - EQBandConfiguration FIR kernel storage

    func testFIRBandConfiguration_KernelStoredAndRetrieved() {
        var band = EQBandConfiguration(
            frequency: 1000, q: 1.0, gain: 0, filterType: .fir, bypass: false)
        let kernel: [Float] = [0.5, 0.25, 0.125]
        band.firKernelLeft = kernel
        band.firKernelDisplayName = "my-ir"

        XCTAssertEqual(band.firKernelLeft, kernel)
        XCTAssertEqual(band.firKernelDisplayName, "my-ir")
    }

    func testFIRBandConfiguration_StandardEncode_OmitsKernelArrays() throws {
        var band = EQBandConfiguration(
            frequency: 1000, q: 1.0, gain: 0, filterType: .fir, bypass: false)
        band.firKernelLeft  = [0.5, 0.25, 0.125]
        band.firKernelRight = [0.5, 0.25, 0.125]
        band.firKernelDisplayName = "my-ir"

        let data = try JSONEncoder().encode(band)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(json?["firKernelLeft"],
            "Standard encode must not include firKernelLeft (too large for preset files)")
        XCTAssertNil(json?["firKernelRight"],
            "Standard encode must not include firKernelRight")
        XCTAssertNotNil(json?["firKernelDisplayName"],
            "Standard encode must include firKernelDisplayName (small string)")
    }

    func testFIRBandConfiguration_KernelInclusiveEncode_IncludesArrays() throws {
        var band = EQBandConfiguration(
            frequency: 1000, q: 1.0, gain: 0, filterType: .fir, bypass: false)
        band.firKernelLeft = [0.5, 0.25, 0.125]
        band.firKernelDisplayName = "my-ir"

        // encodeIncludingKernels writes to the encoder; capture data by round-tripping
        // through a JSONEncoder whose output we can read back.
        struct Wrapper: Encodable {
            let band: EQBandConfiguration
            func encode(to encoder: Encoder) throws {
                try band.encodeIncludingKernels(to: encoder)
            }
        }
        let data = try JSONEncoder().encode(Wrapper(band: band))
        let decoded = try JSONDecoder().decode(EQBandConfiguration.self, from: data)
        XCTAssertEqual(decoded.firKernelLeft, [0.5, 0.25, 0.125])
        XCTAssertEqual(decoded.firKernelDisplayName, "my-ir")
    }

    func testFIRBandConfiguration_DecodeWithoutKernel_ProducesNilKernel() throws {
        // A standard preset without firKernelLeft should decode to nil kernel.
        let band = EQBandConfiguration(
            frequency: 1000, q: 1.0, gain: 0, filterType: .fir, bypass: false)
        let data = try JSONEncoder().encode(band)
        let decoded = try JSONDecoder().decode(EQBandConfiguration.self, from: data)
        XCTAssertNil(decoded.firKernelLeft,
            "Decoding a band without firKernelLeft must produce nil kernel")
    }

    // MARK: - IIR stager skips .fir bands

    func testIIRStager_SkipsFIRBands_ViaCalculateSections() {
        // BiquadMath.calculateSections with .fir must return a non-crashing,
        // non-NaN result (default case fallback in the switch).
        let sections = BiquadMath.calculateSections(
            type: .fir,
            sampleRate: 48000,
            frequency: 1000,
            q: 1.0,
            gain: 0.0,
            slope: .db12)
        // The default case returns at least one section without crashing.
        XCTAssertFalse(sections.isEmpty,
            "calculateSections(.fir) must return at least one section rather than crashing")
        for s in sections {
            XCTAssertFalse(s.b0.isNaN, "calculateSections(.fir) must not produce NaN b0")
            XCTAssertFalse(s.b1.isNaN, "calculateSections(.fir) must not produce NaN b1")
            XCTAssertFalse(s.b2.isNaN, "calculateSections(.fir) must not produce NaN b2")
            XCTAssertFalse(s.a1.isNaN, "calculateSections(.fir) must not produce NaN a1")
            XCTAssertFalse(s.a2.isNaN, "calculateSections(.fir) must not produce NaN a2")
        }
    }

    // MARK: - IRFileLoader sample-rate cap raised

    func testIRFileLoader_ErrorDescription_NoHardcodedRate() {
        let error = IRFileLoader.IRError.sampleRateTooHigh(768000)
        XCTAssertFalse(error.errorDescription?.contains("192") ?? false,
            "IRError.sampleRateTooHigh description must not hardcode '192 kHz' after the cap was raised")
    }

    func testIRFileLoader_ErrorDescription_ContainsRate() {
        let error = IRFileLoader.IRError.sampleRateTooHigh(999000)
        XCTAssertTrue(error.errorDescription?.contains("999000") ?? false,
            "IRError.sampleRateTooHigh description must include the actual rate value")
    }
}
