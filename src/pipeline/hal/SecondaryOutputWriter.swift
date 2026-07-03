// SecondaryOutputWriter.swift
// Secondary HAL output writer for multi-device routing.
//
// Architecture note (A1): multi-device output is implemented via independent
// parallel AUHAL instances — one per target device that differs from the
// primary output device. Clock drift is accepted because:
//   • The aggregate-device path in RenderPipeline is still a stub (configureAggregateDevice
//     is TODO), so we cannot rely on it yet.
//   • For channel-offset writes within the *same* physical/aggregate device,
//     no SecondaryOutputWriter is needed at all — processOutputChannelMatrix
//     writes directly into the correct channel offset of the existing HAL output buffer.
//
// Data flow:
//   Primary render callback (audio thread A) → write() → AudioRingBuffer
//   Secondary AUHAL render callback (audio thread B) ← read() ← AudioRingBuffer
//
// Each SecondaryOutputWriter owns one AudioComponentInstance (AUHAL) targeting
// a specific AudioDeviceID and one AudioRingBuffer per output channel.

import CoreAudio
import AudioToolbox
import Foundation
import Accelerate
import Atomics
import OSLog

/// Writes audio from the primary render callback to a secondary HAL output device
/// via lock-free ring buffers and an AUHAL instance on that device's render thread.
final class SecondaryOutputWriter: @unchecked Sendable {

    // MARK: - Configuration

    struct Config {
        var deviceID: AudioDeviceID
        var deviceUID: String
        /// Number of output channels to write (1 or 2).
        var channelCount: Int
        var nominalSampleRate: Double
        /// Maximum frames the primary callback will ever call write() with.
        var maxFrameCount: Int
    }

    // MARK: - Private State

    private nonisolated(unsafe) var audioUnit: AudioComponentInstance?
    private let ringBuffers: [AudioRingBuffer]
    private let channelCount: Int
    private let config: Config

    // Atomic gain applied before ring-buffer write (linear, ≥ 0)
    private let _gainBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))

    // Scratch buffer for per-frame gain scaling (avoids heap alloc in write())
    private let gainScratch: UnsafeMutablePointer<Float>

    private static let ringCapacity = 16384  // ≈ 341 ms @ 48 kHz — absorbs scheduler jitter
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "SecondaryOutputWriter")

    // MARK: - Init / Deinit

    init(config: Config) {
        self.config = config
        self.channelCount = max(1, config.channelCount)
        self.ringBuffers = (0..<self.channelCount).map { _ in
            AudioRingBuffer(capacity: Self.ringCapacity)
        }
        self.gainScratch = UnsafeMutablePointer<Float>.allocate(capacity: config.maxFrameCount)
        self.gainScratch.initialize(repeating: 0.0, count: config.maxFrameCount)
    }

    deinit {
        stop()
        gainScratch.deinitialize(count: config.maxFrameCount)
        gainScratch.deallocate()
    }

    // MARK: - Lifecycle

    /// Configures and starts the AUHAL output unit targeting `config.deviceID`.
    /// Call from the main thread before the primary pipeline starts.
    /// - Returns: `true` on success.
    @discardableResult
    func start() -> Bool {
        guard audioUnit == nil else { return true }  // already running

        // ── Find AUHAL component ─────────────────────────────────────────
        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("SecondaryOutputWriter: AUHAL component not found")
            return false
        }

        var unit: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            logger.error("SecondaryOutputWriter: AudioComponentInstanceNew failed")
            return false
        }

        // ── Disable input, enable output ─────────────────────────────────
        var zero: UInt32 = 0
        var one:  UInt32 = 1
        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             1, &zero, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             0, &one, UInt32(MemoryLayout<UInt32>.size))

        // ── Bind to target device ─────────────────────────────────────────
        var deviceID = config.deviceID
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            logger.error("SecondaryOutputWriter: set device failed (\(status))")
            AudioComponentInstanceDispose(unit)
            return false
        }

        // ── Set client stream format (Float32 non-interleaved) ───────────
        var format = AudioStreamBasicDescription(
            mSampleRate:       config.nominalSampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel:   32,
            mReserved:         0
        )
        AudioUnitSetProperty(unit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0,
                             &format,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // ── Register render callback ──────────────────────────────────────
        var callbackStruct = AURenderCallbackStruct(
            inputProc:       Self.secondaryRenderCallback,
            inputProcRefCon: Unmanaged.passRetained(self).toOpaque()
        )
        let cbStatus = AudioUnitSetProperty(unit,
                                             kAudioUnitProperty_SetRenderCallback,
                                             kAudioUnitScope_Input,
                                             0,
                                             &callbackStruct,
                                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard cbStatus == noErr else {
            logger.error("SecondaryOutputWriter: set render callback failed (\(cbStatus))")
            Unmanaged.passUnretained(self).release()
            AudioComponentInstanceDispose(unit)
            return false
        }

        guard AudioUnitInitialize(unit) == noErr else {
            logger.error("SecondaryOutputWriter: AudioUnitInitialize failed")
            AudioComponentInstanceDispose(unit)
            return false
        }
        guard AudioOutputUnitStart(unit) == noErr else {
            logger.error("SecondaryOutputWriter: AudioOutputUnitStart failed")
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            return false
        }

        audioUnit = unit
        logger.info("SecondaryOutputWriter: started for device \(self.config.deviceID)")
        return true
    }

    /// Stops and disposes the AUHAL unit. Safe to call multiple times.
    func stop() {
        guard let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        logger.info("SecondaryOutputWriter: stopped for device \(self.config.deviceID)")
    }

    // MARK: - Write (Primary Render Callback Thread)

    /// Called from the PRIMARY device's render callback.
    /// Applies gain and writes each channel into its ring buffer.
    /// Lock-free and real-time safe.
    @inline(__always)
    func write(
        channels: [(buffer: UnsafePointer<Float>, channelIndex: Int)],
        frameCount: Int
    ) {
        let gain = Float(bitPattern: UInt32(bitPattern: _gainBits.load(ordering: .relaxed)))

        for (buf, chIdx) in channels {
            guard chIdx < ringBuffers.count else { continue }
            if gain == 1.0 {
                ringBuffers[chIdx].write(buf, count: frameCount)
            } else {
                // Scale into scratch and write
                var g = gain
                vDSP_vsmul(buf, 1, &g, gainScratch, 1, vDSP_Length(frameCount))
                ringBuffers[chIdx].write(gainScratch, count: frameCount)
            }
        }
    }

    // MARK: - Secondary HAL Render Callback (Secondary Device's Thread)

    private static let secondaryRenderCallback: AURenderCallback = {
        inRefCon, _, _, _, frameCount, ioData -> OSStatus in
        guard let ioData else { return noErr }

        let writer = Unmanaged<SecondaryOutputWriter>.fromOpaque(inRefCon).takeUnretainedValue()
        let abl    = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = Int(frameCount)

        for (chIdx, audioBuf) in abl.enumerated() {
            guard chIdx < writer.ringBuffers.count,
                  let dest = audioBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            writer.ringBuffers[chIdx].read(into: dest, count: frames)
        }
        return noErr
    }

    // MARK: - Gain

    func setGain(_ gainLinear: Float) {
        _gainBits.store(Int32(bitPattern: gainLinear.bitPattern), ordering: .releasing)
    }
}
