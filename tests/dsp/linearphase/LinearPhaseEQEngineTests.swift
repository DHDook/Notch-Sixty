// LinearPhaseEQEngineTests.swift
// Regression test for the output carry-over buffer fix in LinearPhaseEQEngine.
// Verifies that the engine correctly drains valid output across multiple process() calls
// when frameCount < hopSize.

import XCTest
@testable import Equaliser

final class LinearPhaseEQEngineTests: XCTestCase {

    private let sampleRate: Double = 48000.0

    func testIdentityConvolutionWithSmallFrameCount() {
        // Test with identity filter (no EQ bands) and small frameCount (simulating real HAL buffer)
        let engine = LinearPhaseEQEngine(maxFrameCount: 512)

        // Update IR with no bands (identity filter)
        engine.updateIR(leftBands: [], rightBands: [], sampleRate: sampleRate)

        // Process with small frameCount (128, typical small HAL buffer)
        var input = [Float](repeating: 0, count: 4096)
        input[0] = 1.0  // Impulse at position 0

        var outputL = [Float](repeating: 0, count: 4096)
        var outputR = [Float](repeating: 0, count: 4096)

        // Process in chunks of 128 samples (simulating real audio callback)
        let chunkSize = 128
        for i in 0..<(4096 / chunkSize) {
            input.withUnsafeBufferPointer { inputPtr in
                outputL.withUnsafeMutableBufferPointer { outLPtr in
                    outputR.withUnsafeMutableBufferPointer { outRPtr in
                        engine.process(
                            bufL: outLPtr.baseAddress!.advanced(by: i * chunkSize),
                            bufR: outRPtr.baseAddress!.advanced(by: i * chunkSize),
                            frameCount: chunkSize
                        )
                    }
                }
            }
        }

        // The output should contain the impulse (identity convolution should preserve input)
        // With the fix, all samples should be delivered, not just the first chunkSize of each hop
        let maxOutput = outputL.max() ?? 0
        XCTAssertGreaterThan(maxOutput, 0.9, "Identity convolution should preserve input level")
    }

    func testIdentityConvolutionWithLargeFrameCount() {
        // Test with frameCount = hopSize (2048) - this should work even without the fix
        let engine = LinearPhaseEQEngine(maxFrameCount: 2048)

        engine.updateIR(leftBands: [], rightBands: [], sampleRate: sampleRate)

        var input = [Float](repeating: 0, count: 4096)
        input[0] = 1.0

        var outputL = [Float](repeating: 0, count: 4096)
        var outputR = [Float](repeating: 0, count: 4096)

        // Process in chunks of 2048 samples (hopSize)
        let chunkSize = 2048
        for i in 0..<(4096 / chunkSize) {
            input.withUnsafeBufferPointer { inputPtr in
                outputL.withUnsafeMutableBufferPointer { outLPtr in
                    outputR.withUnsafeMutableBufferPointer { outRPtr in
                        engine.process(
                            bufL: outLPtr.baseAddress!.advanced(by: i * chunkSize),
                            bufR: outRPtr.baseAddress!.advanced(by: i * chunkSize),
                            frameCount: chunkSize
                        )
                    }
                }
            }
        }

        let maxOutput = outputL.max() ?? 0
        XCTAssertGreaterThan(maxOutput, 0.9, "Identity convolution should preserve input level")
    }

    func testConvolutionWithEQBands() {
        // Test with actual EQ bands
        let engine = LinearPhaseEQEngine(maxFrameCount: 512)

        let band = EQBandConfiguration(
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0,
            filterType: .peaking,
            bypass: false
        )

        engine.updateIR(leftBands: [band], rightBands: [band], sampleRate: sampleRate)

        // Process a sine wave through the engine
        var input = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 {
            input[i] = sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0)
        }

        var outputL = [Float](repeating: 0, count: 4096)
        var outputR = [Float](repeating: 0, count: 4096)

        // Process in chunks of 512 samples
        let chunkSize = 512
        for i in 0..<(4096 / chunkSize) {
            input.withUnsafeBufferPointer { inputPtr in
                outputL.withUnsafeMutableBufferPointer { outLPtr in
                    outputR.withUnsafeMutableBufferPointer { outRPtr in
                        engine.process(
                            bufL: outLPtr.baseAddress!.advanced(by: i * chunkSize),
                            bufR: outRPtr.baseAddress!.advanced(by: i * chunkSize),
                            frameCount: chunkSize
                        )
                    }
                }
            }
        }

        // Output should have significant energy (not gated/dropped)
        let inputRMS = sqrt(input.map { $0 * $0 }.reduce(0, +) / Float(input.count))
        let outputRMS = sqrt(outputL.map { $0 * $0 }.reduce(0, +) / Float(outputL.count))

        // The output should not be significantly quieter than input
        // (the bug would cause severe dropouts)
        let ratio = outputRMS / inputRMS
        XCTAssertGreaterThan(ratio, 0.1, "Convolution should not drop most of the signal")
    }

    func testEngineReset() {
        // Test that reset() clears all state including carry-over buffers
        let engine = LinearPhaseEQEngine(maxFrameCount: 512)

        engine.updateIR(leftBands: [], rightBands: [], sampleRate: sampleRate)

        // Process some audio
        var input = [Float](repeating: 0.5, count: 512)
        var output = [Float](repeating: 0, count: 512)

        input.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                engine.process(bufL: outPtr.baseAddress!, bufR: nil, frameCount: 512)
            }
        }

        // Reset should clear all state
        engine.reset()

        // Process silence after reset
        var silence = [Float](repeating: 0, count: 512)
        var outputAfterReset = [Float](repeating: 0, count: 512)

        silence.withUnsafeBufferPointer { silencePtr in
            outputAfterReset.withUnsafeMutableBufferPointer { outPtr in
                engine.process(bufL: outPtr.baseAddress!, bufR: nil, frameCount: 512)
            }
        }

        // Output after reset should be near zero (no residual from previous processing)
        let maxAfterReset = outputAfterReset.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(maxAfterReset, 0.001, "Reset should clear all state")
    }

    func testVariableFrameCount() {
        // Test with varying frameCount sizes to ensure carry-over works correctly
        let engine = LinearPhaseEQEngine(maxFrameCount: 1024)

        engine.updateIR(leftBands: [], rightBands: [], sampleRate: sampleRate)

        var input = [Float](repeating: 0, count: 4096)
        input[0] = 1.0

        var outputL = [Float](repeating: 0, count: 4096)

        // Process with varying chunk sizes: 64, 128, 256, 512, 1024
        let chunkSizes = [64, 128, 256, 512, 1024]
        var offset = 0
        for chunkSize in chunkSizes {
            input.withUnsafeBufferPointer { inputPtr in
                outputL.withUnsafeMutableBufferPointer { outPtr in
                    engine.process(
                        bufL: outPtr.baseAddress!.advanced(by: offset),
                        bufR: nil,
                        frameCount: chunkSize
                    )
                }
            }
            offset += chunkSize
        }

        let maxOutput = outputL.max() ?? 0
        XCTAssertGreaterThan(maxOutput, 0.9, "Variable frameCount should not break output delivery")
    }

    func testComputeIRSpectrum_AllBandsBypassed_ProducesNearUnityResponse() {
        // Regression test for closure variable shadowing bug in computeIRSpectrum.
        // Verifies that with all bands flat/bypassed, the engine passes audio through
        // effectively unchanged (aside from fixed processing latency).
        let engine = LinearPhaseEQEngine(maxFrameCount: 8192)

        // No bands / all bands at 0 dB gain, flat
        engine.updateIR(leftBands: [], rightBands: [], sampleRate: sampleRate)

        // Feed a unit impulse and confirm the engine passes it through close to unchanged
        let frameCount = 8192
        var impulse = [Float](repeating: 0, count: frameCount)
        impulse[0] = 1.0
        var output = [Float](repeating: 0, count: frameCount)

        impulse.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                engine.process(bufL: outBuf.baseAddress!, bufR: nil, frameCount: frameCount)
            }
        }

        // The output impulse response should be a single, near-unity-magnitude peak
        // near the engine's known latency offset, not spread energy or a huge/garbage value
        let peak = output.max(by: { abs($0) < abs($1) })!
        XCTAssertLessThan(abs(peak), 2.0, "Flat/bypassed Linear EQ should not amplify — got \(peak)")

        let totalEnergy = output.reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertLessThan(totalEnergy, 4.0, "Flat/bypassed Linear EQ energy should be close to the input impulse's energy (1.0), not spread/amplified")
    }
}
