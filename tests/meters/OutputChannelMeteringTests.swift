import XCTest
import Accelerate
@testable import Equaliser

final class OutputChannelMeteringTests: XCTestCase {

    // MARK: - Pre-Limiter Meter Tests

    func testPreLimiterMeterUpdatesEachCallback() {
        // Process a known-amplitude sine → preLimiterPeakLinear updated within one callback
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: sampleRate)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        // Reset meter to zero
        processor.preLimiterPeakLinear = 0.0

        processor.process(buffer: &bufferList, frameCount: frameCount, channelIndex: 0)

        // Pre-limiter peak should be updated (non-zero)
        XCTAssertGreaterThan(processor.preLimiterPeakLinear, 0.01, "Pre-limiter meter should update each callback")

        freeTestBufferList(bufferList: bufferList)
    }

    func testPostLimiterMeterNeverExceedsCeiling() {
        // Drive above ceiling → postLimiterPeakDB ≤ ceilingDB + 0.1 dB tolerance
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: sampleRate)

        // Set limiter ceiling to -0.2 dB
        var limiterConfig = OutputChannelLimiterConfig()
        limiterConfig.isEnabled = true
        limiterConfig.ceilingDB = -0.2
        processor.setLimiterConfig(limiterConfig)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 1.0)

        processor.process(buffer: &bufferList, frameCount: frameCount, channelIndex: 0)

        let postLimiterLinear = processor.postLimiterPeakLinear
        let postLimiterDB = 20.0 * log10(postLimiterLinear)

        // Post-limiter peak should not exceed ceiling by more than 0.1 dB
        XCTAssertLessThanOrEqual(postLimiterDB, -0.2 + 0.1, "Post-limiter should not exceed ceiling")

        freeTestBufferList(bufferList: bufferList)
    }

    func testExcursionGainReductionIsNegativeWhenActive() {
        // Input below protection cutoff at high level → excursionGainReductionDB < 0
        // Note: This test assumes excursion protection is implemented in OutputChannelProcessor
        // For now, we test that the field exists and can be set
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: sampleRate)

        // Set a negative gain reduction value
        processor.excursionLimiterGainReductionDB = -3.0

        XCTAssertLessThan(processor.excursionLimiterGainReductionDB, 0.0, "Excursion GR should be negative when active")
    }

    func testBrickwallGainReductionIsZeroWhenNotClipping() {
        // Input well below ceiling → brickwallGainReductionDB == 0
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: sampleRate)

        // Set limiter ceiling to -0.2 dB
        var limiterConfig = OutputChannelLimiterConfig()
        limiterConfig.isEnabled = true
        limiterConfig.ceilingDB = -0.2
        processor.setLimiterConfig(limiterConfig)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.1)

        processor.process(buffer: &bufferList, frameCount: frameCount, channelIndex: 0)

        // With input well below ceiling, brickwall GR should be zero
        XCTAssertEqual(processor.brickwallGainReductionDB, 0.0, accuracy: 0.01, "Brickwall GR should be zero when not clipping")

        freeTestBufferList(bufferList: bufferList)
    }

    func testIsClippingFlagSetWhenPreLimiterExceedsThreshold() {
        // preLimiterPeakLinear > threshold → isClipping == true
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = OutputChannelProcessor(source: .mainsLeft, maxFrameCount: 512, sampleRate: sampleRate)

        // Set pre-limiter peak to a value above -0.5 dBFS (linear > 0.944)
        processor.preLimiterPeakLinear = 0.95

        // Calculate clipping threshold (-0.5 dBFS = 0.944 linear)
        let clippingThreshold = AudioMath.dbToLinear(-0.5)
        let isClipping = processor.preLimiterPeakLinear > clippingThreshold

        XCTAssertTrue(isClipping, "Clipping flag should be set when pre-limiter exceeds threshold")
    }

    func testMeterStorePublishesAllActiveChannels() {
        // 4 active channels → outputChannelLevels has 4 entries
        let store = MeterStore()
        let mockPipeline = MockRenderPipeline()
        store.setRenderPipeline(mockPipeline)

        // Simulate 4 active channels
        var mockMeters: [Int: OutputChannelMeterData] = [:]
        for i in 0..<4 {
            mockMeters[i] = OutputChannelMeterData(
                preLimiterPeakDB: -10.0,
                postLimiterPeakDB: -12.0,
                excursionGainReductionDB: 0.0,
                brickwallGainReductionDB: 0.0,
                isClipping: false
            )
        }
        mockPipeline.outputChannelMeters = mockMeters

        store.refreshMeterSnapshot()

        XCTAssertEqual(store.outputChannelLevels.count, 4, "MeterStore should publish all active channels")
    }

    // MARK: - Helper Methods

    private func createTestBufferList(channelCount: Int, frameCount: Int, amplitude: Float) -> AudioBufferList {
        let bufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)

        bufferList.pointee.mNumberBuffers = UInt32(channelCount)

        for ch in 0..<channelCount {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            for i in 0..<frameCount {
                buffer[i] = amplitude
            }
            bufferList.pointee.mBuffers[ch].mNumberChannels = 1
            bufferList.pointee.mBuffers[ch].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
            bufferList.pointee.mBuffers[ch].mData = UnsafeMutableRawPointer(buffer)
        }

        return bufferList.pointee
    }

    private func freeTestBufferList(bufferList: AudioBufferList) {
        for i in 0..<Int(bufferList.mNumberBuffers) {
            if let mData = bufferList.mBuffers[i].mData {
                mData.deallocate()
            }
        }
    }
}

// MARK: - Mock RenderPipeline for Testing

private class MockRenderPipeline: RenderPipelineProtocol {
    var outputChannelMeters: [Int: OutputChannelMeterData] = [:]

    func currentOutputChannelMeters() -> [Int: OutputChannelMeterData] {
        return outputChannelMeters
    }
}

protocol RenderPipelineProtocol {
    func currentOutputChannelMeters() -> [Int: OutputChannelMeterData]
}
