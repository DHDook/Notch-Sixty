// MicCaptureSession.swift
// Self-contained HAL microphone capture session.
// Owns a HALIOManager and delivers captured audio to a consumer closure
// on a background dispatch queue.

import Foundation
import AudioToolbox
import os.log

/// Manages a single physical microphone input session via a HAL Audio Unit.
///
/// Usage:
///   1. Create with `init(deviceID:sampleRate:channelCount:)`.
///   2. Call `start(onSamples:)` to begin capture.
///   3. The `onSamples` closure is called on a background queue for each
///      buffer of captured audio.
///   4. Call `stop()` when done.
///
/// Thread safety: `start()` and `stop()` must be called from the main thread.
/// The `onSamples` closure is called from a serial background queue.
final class MicCaptureSession: @unchecked Sendable {

    // MARK: - Types

    /// A captured audio buffer: channel index → sample array.
    typealias AudioBuffer = [Int: [Float]]

    // MARK: - Private state

    private nonisolated(unsafe) var halManager: HALIOManager?
    private let deviceID: AudioDeviceID
    private let sampleRate: Double
    private let channelCount: Int

    private nonisolated(unsafe) var onSamples: ((AudioBuffer) -> Void)?
    private let deliveryQueue = DispatchQueue(
        label: "net.knage.equaliser.MicCaptureSession",
        qos: .userInitiated)

    // Ring buffer for thread-safe transfer from HAL callback to delivery queue.
    // One buffer per channel; size = 4096 × channelCount floats.
    static let ringBufferFrameCapacity = 4096
    private var ringBuffers: [[Float]] = []
    private var writePositions: [Int] = []
    private var readPositions:  [Int] = []

    // C-compatible callback context stored on the heap.
    // Must outlive the HAL unit — released only in deinit.
    private var callbackContext: UnsafeMutablePointer<MicCallbackContext>?

    private let logger = Logger(subsystem: "net.knage.equaliser", category: "MicCaptureSession")

    // MARK: - Init / deinit

    /// Creates a mic capture session for the given device.
    /// - Parameters:
    ///   - deviceID: CoreAudio `AudioDeviceID` of the physical mic.
    ///   - sampleRate: Expected device sample rate. Used only for buffer sizing.
    ///   - channelCount: Number of input channels to capture (default 1).
    init(deviceID: AudioDeviceID, sampleRate: Double, channelCount: Int = 1) {
        self.deviceID     = deviceID
        self.sampleRate   = sampleRate
        self.channelCount = channelCount

        let cap = Self.ringBufferFrameCapacity
        ringBuffers    = Array(repeating: Array(repeating: Float(0), count: cap * 2), count: channelCount)
        writePositions = Array(repeating: 0, count: channelCount)
        readPositions  = Array(repeating: 0, count: channelCount)
    }

    deinit {
        if let ctx = callbackContext {
            ctx.deallocate()
            callbackContext = nil
        }
        // Note: stop() is @MainActor and cannot be called from deinit.
        // Callers must explicitly call stop() before the session is deallocated.
    }

    // MARK: - Public API

    /// Starts capture. The `onSamples` closure is called on a background queue.
    /// - Parameter onSamples: Receives a dictionary mapping channel index to sample buffer.
    ///   Called approximately once per HAL callback (512–1024 samples at typical rates).
    @MainActor
    func start(onSamples: @escaping (AudioBuffer) -> Void) {
        guard halManager == nil else {
            logger.warning("MicCaptureSession.start() called while already running")
            return
        }

        self.onSamples = onSamples

        let manager = HALIOManager(mode: .inputOnly)

        guard case .success = manager.configure(deviceID: deviceID) else {
            logger.error("MicCaptureSession: failed to configure HAL for device \(self.deviceID)")
            return
        }
        guard case .success = manager.initialize() else {
            logger.error("MicCaptureSession: failed to initialize HAL unit")
            return
        }

        // Allocate and populate the callback context on the heap.
        // The C callback cannot capture Swift values — it receives only the raw pointer.
        let ctx = UnsafeMutablePointer<MicCallbackContext>.allocate(capacity: 1)
        ctx.initialize(to: MicCallbackContext(
            session: Unmanaged.passUnretained(self).toOpaque(),
            audioUnit: manager.unsafeAudioUnit!,
            channelCount: Int32(channelCount),
            ringBufferCapacity: Int32(Self.ringBufferFrameCapacity * 2)
        ))
        callbackContext = ctx

        // Register the C AURenderCallback
        let result = manager.setInputCallback(micInputCallback, context: ctx)
        guard case .success = result else {
            logger.error("MicCaptureSession: failed to register input callback")
            ctx.deallocate()
            callbackContext = nil
            return
        }

        guard case .success = manager.start() else {
            logger.error("MicCaptureSession: failed to start HAL unit")
            ctx.deallocate()
            callbackContext = nil
            return
        }

        halManager = manager
        logger.info("MicCaptureSession: started capture on device \(self.deviceID)")
    }

    /// Stops capture and releases the HAL unit.
    @MainActor
    func stop() {
        guard let manager = halManager else { return }
        _ = manager.clearInputCallback()
        manager.stop()
        halManager = nil
        onSamples  = nil
        logger.info("MicCaptureSession: stopped")
    }

    // MARK: - Internal: called from the C callback

    /// Called from the AURenderCallback on the HAL real-time thread.
    /// Renders a buffer from the HAL unit and writes samples into the ring buffer.
    /// Then schedules delivery on the background queue.
    fileprivate func deliverFromCallback(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?,
        audioUnit: AudioUnit
    ) {
        // Render into ioData from the input element
        let status = AudioUnitRender(
            audioUnit,
            actionFlags,
            timestamp,
            1,   // input element = 1 for AUHAL
            frameCount,
            ioData!
        )
        guard status == noErr, let abl = ioData else { return }

        let abuList = UnsafeMutableAudioBufferListPointer(abl)
        let n = Int(frameCount)

        // Write each channel into the ring buffer (lock-free circular)
        for (ch, buf) in abuList.enumerated() where ch < channelCount {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let cap = ringBuffers[ch].count
            let wp  = writePositions[ch]
            for i in 0..<n {
                ringBuffers[ch][(wp + i) % cap] = data[i]
            }
            writePositions[ch] = (wp + n) % cap
        }

        // Schedule delivery off the real-time thread
        let capturedBuffers = ringBuffers
        let capturedWP      = writePositions
        let chCount         = channelCount
        let frameN          = n

        deliveryQueue.async { [weak self] in
            guard let self = self, let deliver = self.onSamples else { return }
            var out = AudioBuffer()
            for ch in 0..<chCount {
                let cap = capturedBuffers[ch].count
                let wp  = capturedWP[ch]
                let rp  = (wp - frameN + cap) % cap
                var samples = [Float](repeating: 0, count: frameN)
                for i in 0..<frameN {
                    samples[i] = capturedBuffers[ch][(rp + i) % cap]
                }
                out[ch] = samples
            }
            deliver(out)
        }
    }
}

// MARK: - C callback context

/// Plain-C-compatible context struct passed as `inRefCon` to the HAL input callback.
private struct MicCallbackContext {
    var session: UnsafeMutableRawPointer    // Unmanaged<MicCaptureSession>
    var audioUnit: AudioComponentInstance  // HAL audio unit for AudioUnitRender
    var channelCount: Int32
    var ringBufferCapacity: Int32
}

// MARK: - C AURenderCallback (must be a plain C function — no captures)

private let micInputCallback: AURenderCallback = { (
    inRefCon,
    ioActionFlags,
    inTimeStamp,
    inBusNumber,
    inNumberFrames,
    ioData
) -> OSStatus in
    let ctx = inRefCon.assumingMemoryBound(to: MicCallbackContext.self)
    // Bridge back to Swift object — unretained, lifetime managed by MicCaptureSession.deinit
    let session = Unmanaged<MicCaptureSession>
        .fromOpaque(ctx.pointee.session)
        .takeUnretainedValue()

    session.deliverFromCallback(
        actionFlags: ioActionFlags,
        timestamp: inTimeStamp,
        frameCount: inNumberFrames,
        ioData: ioData,
        audioUnit: ctx.pointee.audioUnit
    )
    return noErr
}
