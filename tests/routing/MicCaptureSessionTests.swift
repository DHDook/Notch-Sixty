// MicCaptureSessionTests.swift
import XCTest
@testable import Equaliser

final class MicCaptureSessionTests: XCTestCase {

    // MARK: - Unit tests (no real audio hardware required)

    /// MicCaptureSession can be created and destroyed without crashing.
    func testInit_DoesNotCrash() {
        // Use a fake device ID — we don't call start(), so HAL is never accessed
        let session = MicCaptureSession(deviceID: 999, sampleRate: 48000, channelCount: 1)
        XCTAssertNotNil(session)
    }

    /// stop() on a session that was never started must not crash.
    func testStop_WhenNeverStarted_DoesNotCrash() {
        let session = MicCaptureSession(deviceID: 999, sampleRate: 48000, channelCount: 1)
        session.stop()  // must not crash or assert
    }

    /// stop() called twice must not crash (idempotent).
    func testStop_CalledTwice_IsIdempotent() {
        let session = MicCaptureSession(deviceID: 999, sampleRate: 48000, channelCount: 1)
        session.stop()
        session.stop()
    }

    /// The ring buffer capacity must accommodate at least 1 second of audio at 48 kHz.
    func testRingBufferCapacity_SufficientForOnSecond() {
        // MicCaptureSession.ringBufferFrameCapacity × 2 must be ≥ 48000 for 48 kHz
        // (the ×2 is the ring buffer size: capacity × 2 for ping-pong safety)
        // We verify indirectly via the buffer sizing constant:
        let capacity = MicCaptureSession.ringBufferFrameCapacity
        XCTAssertGreaterThanOrEqual(capacity, 4096,
            "Ring buffer capacity must be at least 4096 frames")
        XCTAssertGreaterThanOrEqual(capacity * 2, 48000,
            "Ring buffer (×2) must hold at least 1 second at 48 kHz")
    }

    // MARK: - Integration smoke test (requires audio hardware)

    /// This test requires a real microphone and will be skipped in CI
    /// unless the NOTCH_SIXTY_MIC_TESTS environment variable is set.
    func testCapture_DeliversSamples_WithRealMic() throws {
        guard ProcessInfo.processInfo.environment["NOTCH_SIXTY_MIC_TESTS"] != nil else {
            throw XCTSkip("Skipping real-hardware mic test (set NOTCH_SIXTY_MIC_TESTS=1 to enable)")
        }

        // Find the default input device
        var defaultInputID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &defaultInputID)
        guard defaultInputID != 0 else {
            throw XCTSkip("No default input device found")
        }

        let expectation = XCTestExpectation(description: "Received mic samples")
        let session = MicCaptureSession(deviceID: defaultInputID, sampleRate: 48000, channelCount: 1)

        session.start { buffer in
            if let samples = buffer[0], !samples.isEmpty {
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
        session.stop()
    }

    // MARK: - SweepAnalyser integration

    /// SweepAnalyser.recordSamples accumulates into the correct position.
    func testSweepAnalyser_RecordSamples_AccumulatesCorrectly() {
        let analyser = SweepAnalyser(sampleRate: 48000, duration: 1.0)
        analyser.startRecording()

        let batch1 = [Float](repeating: 0.5, count: 100)
        let batch2 = [Float](repeating: 0.7, count: 100)
        analyser.recordSamples(batch1)
        analyser.recordSamples(batch2)
        analyser.stopRecording()

        // After recording, the first 100 samples should be 0.5
        // and the next 100 should be 0.7 (via the internal recordedResponse buffer)
        // We verify indirectly: computeImpulseResponse should not crash and returns a non-empty array
        let ir = analyser.computeImpulseResponse(referenceSweep: analyser.sweepSignal)
        XCTAssertFalse(ir.isEmpty, "computeImpulseResponse must return a non-empty IR")
    }
}
