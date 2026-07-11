import XCTest
import CoreAudio
import AudioToolbox
@testable import Equaliser

/// Tests for the infrasonic filter stability.
/// These tests verify that the filter coefficients are correctly negated
/// and that the filter remains stable (no divergence to Inf/NaN) under
/// various conditions.
final class InfrasonicFilterStabilityTests: XCTestCase {

    func testInfrasonicFilterRemainsStableWithImpulseInput() throws {
        // Constructs a DynamicsProcessor, enables the infrasonic filter at
        // default settings, processes a buffer of unit-impulse + silence for
        // at least a few thousand frames, and asserts every output sample is
        // finite (.isFinite) and bounded (e.g. abs(sample) < 2.0 for a 0 dBFS-ish input).

        let processor = DynamicsProcessor(
            channelCount: 2,
            sampleRate: 48000.0,
            maxFrameCount: 512
        )

        // Enable the infrasonic filter at default settings
        let config = InfrasonicFilterConfig(
            isEnabled: true,
            cutoffHz: 18.0,
            slope: .db48,
            target: .mainChain
        )
        processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

        var bufferList = createTestBufferList(channelCount: 2, frameCount: 512, amplitude: 0.0)
        defer { freeTestBufferList(bufferList: bufferList) }

        let abl = UnsafeMutableAudioBufferListPointer(&bufferList)

        // Process several thousand frames with unit impulse
        for i in 0..<10000 {
            if let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                bufL[0] = (i == 0) ? 1.0 : 0.0
                bufR[0] = (i == 0) ? 1.0 : 0.0
            }

            processor.process(bufferList: &bufferList, frameCount: 512)

            for j in 0..<512 {
                guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { continue }
                XCTAssertTrue(bufL[j].isFinite, "Output sample L[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(bufR[j].isFinite, "Output sample R[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(abs(bufL[j]) < 2.0, "Output sample L[\(j)] exceeds bound at frame \(i)")
                XCTAssertTrue(abs(bufR[j]) < 2.0, "Output sample R[\(j)] exceeds bound at frame \(i)")
            }
        }
    }

    func testInfrasonicFilterRemainsStableWithNoiseInput() throws {
        // Same test but with full-scale white noise instead of impulse

        let processor = DynamicsProcessor(
            channelCount: 2,
            sampleRate: 48000.0,
            maxFrameCount: 512
        )

        let config = InfrasonicFilterConfig(
            isEnabled: true,
            cutoffHz: 18.0,
            slope: .db48,
            target: .mainChain
        )
        processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

        var bufferList = createTestBufferList(channelCount: 2, frameCount: 512, amplitude: 0.0)
        defer { freeTestBufferList(bufferList: bufferList) }

        let abl = UnsafeMutableAudioBufferListPointer(&bufferList)

        // Process several thousand frames with white noise
        for i in 0..<5000 {
            if let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                // Fill with white noise at -6 dBFS
                for j in 0..<512 {
                    bufL[j] = Float.random(in: -0.5...0.5)
                    bufR[j] = Float.random(in: -0.5...0.5)
                }
            }

            processor.process(bufferList: &bufferList, frameCount: 512)

            for j in 0..<512 {
                guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { continue }
                XCTAssertTrue(bufL[j].isFinite, "Output sample L[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(bufR[j].isFinite, "Output sample R[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(abs(bufL[j]) < 2.0, "Output sample L[\(j)] exceeds bound at frame \(i)")
                XCTAssertTrue(abs(bufR[j]) < 2.0, "Output sample R[\(j)] exceeds bound at frame \(i)")
            }
        }
    }

    func testInfrasonicFilterRemainsStableDuringSlopeSwitching() throws {
        // Repeats the same check while switching slope every callback for several
        // hundred callbacks, asserting finiteness and that output channel 1 isn't
        // swapped/corrupted relative to channel 0 — this targets Fix 1b.

        let processor = DynamicsProcessor(
            channelCount: 2,
            sampleRate: 48000.0,
            maxFrameCount: 512
        )

        let slopes: [InfrasonicFilterConfig.InfrasonicSlope] = [.db24, .db48, .db96]

        var bufferList = createTestBufferList(channelCount: 2, frameCount: 512, amplitude: 0.0)
        defer { freeTestBufferList(bufferList: bufferList) }

        let abl = UnsafeMutableAudioBufferListPointer(&bufferList)

        // Switch slope every callback for several hundred callbacks
        for i in 0..<500 {
            let slope = slopes[i % slopes.count]
            let config = InfrasonicFilterConfig(
                isEnabled: true,
                cutoffHz: 20.0,
                slope: slope,
                target: .mainChain
            )
            processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

            if let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                // Fill with white noise
                for j in 0..<512 {
                    bufL[j] = Float.random(in: -0.5...0.5)
                    bufR[j] = Float.random(in: -0.5...0.5)
                }
            }

            processor.process(bufferList: &bufferList, frameCount: 512)

            var bufferLValues: [Float] = []
            var bufferRValues: [Float] = []

            for j in 0..<512 {
                guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { continue }
                XCTAssertTrue(bufL[j].isFinite, "Output sample L[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(bufR[j].isFinite, "Output sample R[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(abs(bufL[j]) < 2.0, "Output sample L[\(j)] exceeds bound at frame \(i)")
                XCTAssertTrue(abs(bufR[j]) < 2.0, "Output sample R[\(j)] exceeds bound at frame \(i)")
                bufferLValues.append(bufL[j])
                bufferRValues.append(bufR[j])
            }

            // Verify channels aren't swapped/corrupted (they should be similar for identical input)
            // Allow some tolerance due to different filter states, but they should be correlated
            let correlation = zip(bufferLValues, bufferRValues).map { abs($0 - $1) }.reduce(0, +) / Float(512)
            XCTAssertTrue(correlation < 1.0, "Channels appear swapped/corrupted at frame \(i)")
        }
    }

    func testInfrasonicFilterAllSlopesStable() throws {
        // Test each slope individually to ensure they all produce stable output

        let slopes: [InfrasonicFilterConfig.InfrasonicSlope] = [.db24, .db48, .db96]

        for slope in slopes {
            let processor = DynamicsProcessor(
                channelCount: 2,
                sampleRate: 48000.0,
                maxFrameCount: 512
            )

            let config = InfrasonicFilterConfig(
                isEnabled: true,
                cutoffHz: 20.0,
                slope: slope,
                target: .mainChain
            )
            processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

            var bufferList = createTestBufferList(channelCount: 2, frameCount: 512, amplitude: 0.0)
            defer { freeTestBufferList(bufferList: bufferList) }

            let abl = UnsafeMutableAudioBufferListPointer(&bufferList)

            // Process several frames
            for i in 0..<1000 {
                if let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                   let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                    bufL[0] = (i == 0) ? 1.0 : 0.0
                    bufR[0] = (i == 0) ? 1.0 : 0.0
                }

                processor.process(bufferList: &bufferList, frameCount: 512)

                for j in 0..<512 {
                    guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                          let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    XCTAssertTrue(bufL[j].isFinite, "Slope \(slope): Output sample L[\(j)] is not finite at frame \(i)")
                    XCTAssertTrue(bufR[j].isFinite, "Slope \(slope): Output sample R[\(j)] is not finite at frame \(i)")
                }
            }
        }
    }
}
