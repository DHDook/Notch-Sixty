// PLLSRCWriter.swift
// PLL-corrected secondary output writer for multi-device synchronisation (Mode 3).
// Writes audio to a secondary HAL device with fractional rate correction applied
// by SRCProcessor to maintain sample-accurate clock alignment with the primary.
//
// One PLLSRCWriter per physical secondary device — channelMap routes potentially
// many processing channels onto this one device's physical outputs, all sharing one
// DeviceClockPLL since they share one physical clock. Internally, physical channels
// are processed in pairs through SRCProcessor purely as a compute-sharing grouping.
//
// Data flow:
//   Primary render callback (thread A) → writePrimary() → SRCProcessor → AudioRingBuffer
//   Secondary AUHAL render callback (thread B) ← reads AudioRingBuffer

import CoreAudio
import AudioToolbox
import Foundation
import Accelerate
import Atomics
import OSLog

final class PLLSRCWriter: @unchecked Sendable {

    struct Config {
        var deviceID: AudioDeviceID
        var deviceUID: String
        /// One entry per device output channel — see ChannelMapSlot.
        var channelMap: [ChannelMapSlot]
        var nominalSampleRate: Double
        var pllConfig: DeviceClockPLL.Config = .init()
        var maxFrameCount: Int = Int(AudioConstants.maxFrameCount)
    }

    nonisolated(unsafe) private var audioUnit: AudioComponentInstance?
    private let pll: DeviceClockPLL
    private let config: Config

    private let srcProcessors: [SRCProcessor]
    private let srcOutL: [UnsafeMutablePointer<Float>]
    private let srcOutR: [UnsafeMutablePointer<Float>]
    private let maxOutFrames: Int

    private let ringBuffers: [AudioRingBuffer]
    private var isCallbackRefRetained = false

    /// Total physical output channels on this device (= channelMap.count).
    let channelCount: Int
    /// Exposes the channel map for this device — see ChannelMapSlot.
    var channelMap: [ChannelMapSlot] { config.channelMap }

    private let _gainBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))
    private let overflowCounts: [ManagedAtomic<UInt64>]

    private static let ringBufferCapacity = 16384
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "PLLSRCWriter")

    init(config: Config) {
        self.config = config
        self.channelCount = max(1, config.channelMap.count)

        pll = DeviceClockPLL(deviceUID: config.deviceUID,
                             nominalSampleRate: config.nominalSampleRate,
                             config: config.pllConfig)

        let pairCount = (self.channelCount + 1) / 2
        let processors = (0..<pairCount).map { _ -> SRCProcessor in
            let src = SRCProcessor(maxFrameCount: config.maxFrameCount)
            src.configure(inputRate: config.nominalSampleRate, outputRate: config.nominalSampleRate)
            return src
        }
        self.srcProcessors = processors
        let maxOutFrames = processors.first?.maxOutFrames ?? (config.maxFrameCount * 10)
        self.maxOutFrames = maxOutFrames

        self.srcOutL = (0..<pairCount).map { _ in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: maxOutFrames)
            ptr.initialize(repeating: 0, count: maxOutFrames)
            return ptr
        }
        self.srcOutR = (0..<pairCount).map { _ in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: maxOutFrames)
            ptr.initialize(repeating: 0, count: maxOutFrames)
            return ptr
        }

        self.ringBuffers = (0..<self.channelCount).map { _ in
            AudioRingBuffer(capacity: Self.ringBufferCapacity)
        }
        self.overflowCounts = (0..<self.channelCount).map { _ in ManagedAtomic<UInt64>(0) }
    }

    deinit {
        stop()
        for ptr in srcOutL { ptr.deinitialize(count: self.maxOutFrames); ptr.deallocate() }
        for ptr in srcOutR { ptr.deinitialize(count: self.maxOutFrames); ptr.deallocate() }
    }

    /// Called from the PRIMARY device's render callback. `channelIndex` in `channels`
    /// is the physical device-channel slot (matching config.channelMap's index).
    @inline(__always)
    func writePrimary(
        channels: [(buffer: UnsafePointer<Float>, channelIndex: Int)],
        frameCount: Int,
        primaryHostTime: UInt64
    ) {
        pll.recordPrimaryTimestamp(primaryHostTime)

        let correction = pll.correctionFactor
        for src in srcProcessors {
            src.setRateCorrection(correction)
        }

        let gain = Float(bitPattern: UInt32(bitPattern: _gainBits.load(ordering: .relaxed)))

        for pairIdx in 0..<srcProcessors.count {
            let chA = pairIdx * 2
            let chB = chA + 1
            let bufA = channels.first(where: { $0.channelIndex == chA })?.buffer
            let bufB = chB < channelCount ? channels.first(where: { $0.channelIndex == chB })?.buffer : nil

            guard bufA != nil || bufB != nil else { continue }

            let outCount: Int
            if let bufA, let bufB {
                outCount = srcProcessors[pairIdx].process(
                    inL: bufA, inR: bufB,
                    outL: srcOutL[pairIdx], outR: srcOutR[pairIdx],
                    frameCount: frameCount
                )
            } else if let bufA {
                outCount = srcProcessors[pairIdx].process(
                    inL: bufA, inR: nil,
                    outL: srcOutL[pairIdx], outR: nil,
                    frameCount: frameCount
                )
            } else {
                outCount = srcProcessors[pairIdx].process(
                    inL: bufB!, inR: nil,
                    outL: srcOutL[pairIdx], outR: nil,
                    frameCount: frameCount
                )
            }

            if gain != 1.0 {
                var g = gain
                vDSP_vsmul(srcOutL[pairIdx], 1, &g, srcOutL[pairIdx], 1, vDSP_Length(outCount))
                if bufA != nil && bufB != nil {
                    vDSP_vsmul(srcOutR[pairIdx], 1, &g, srcOutR[pairIdx], 1, vDSP_Length(outCount))
                }
            }

            if bufA != nil && bufB != nil {
                let w0 = ringBuffers[chA].write(srcOutL[pairIdx], count: outCount)
                if w0 < outCount { overflowCounts[chA].wrappingIncrement(ordering: .relaxed) }
                let w1 = ringBuffers[chB].write(srcOutR[pairIdx], count: outCount)
                if w1 < outCount { overflowCounts[chB].wrappingIncrement(ordering: .relaxed) }
            } else if bufA != nil {
                let w0 = ringBuffers[chA].write(srcOutL[pairIdx], count: outCount)
                if w0 < outCount { overflowCounts[chA].wrappingIncrement(ordering: .relaxed) }
            } else {
                let w0 = ringBuffers[chB].write(srcOutL[pairIdx], count: outCount)
                if w0 < outCount { overflowCounts[chB].wrappingIncrement(ordering: .relaxed) }
            }
        }
    }

    private static let secondaryRenderCallback: AURenderCallback = {
        inRefCon, ioActionFlags, inTimeStamp, _, frameCount, ioData -> OSStatus in
        guard let ioData = ioData else { return noErr }
        let writer = Unmanaged<PLLSRCWriter>.fromOpaque(inRefCon).takeUnretainedValue()
        writer.pll.recordSecondaryTimestamp(inTimeStamp.pointee.mHostTime, frameCount: Int(frameCount))

        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = Int(frameCount)

        return withUnsafeTemporaryAllocation(of: Float.self, capacity: frames) { scratch in
            guard let scratchBase = scratch.baseAddress else { return noErr }
            for (chIdx, buf) in abl.enumerated() {
                guard chIdx < writer.ringBuffers.count else { continue }
                guard let dest = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let read = writer.ringBuffers[chIdx].read(into: scratchBase, count: frames)
                memcpy(dest, scratchBase, read * MemoryLayout<Float>.size)
                if read < frames {
                    memset(dest + read, 0, (frames - read) * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }
    }

    func setGain(_ gainLinear: Float) {
        _gainBits.store(Int32(bitPattern: gainLinear.bitPattern), ordering: .releasing)
    }

    func getOverflowCounts() -> [UInt64] {
        overflowCounts.map { $0.load(ordering: .relaxed) }
    }

    var isLocked: Bool { pll.isLocked }

    @discardableResult
    func start() -> Bool {
        guard audioUnit == nil else { return true }

        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("PLLSRCWriter: AUHAL component not found")
            return false
        }

        var unit: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            logger.error("PLLSRCWriter: AudioComponentInstanceNew failed")
            return false
        }

        var zero: UInt32 = 0
        var one:  UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size))

        var deviceID = config.deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            logger.error("PLLSRCWriter: set device failed (\(status))")
            AudioComponentInstanceDispose(unit)
            return false
        }

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
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0,
                             &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        var callbackStruct = AURenderCallbackStruct(
            inputProc:       Self.secondaryRenderCallback,
            inputProcRefCon: Unmanaged.passRetained(self).toOpaque()
        )
        isCallbackRefRetained = true
        let cbStatus = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                             kAudioUnitScope_Input, 0,
                                             &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard cbStatus == noErr else {
            logger.error("PLLSRCWriter: set render callback failed (\(cbStatus))")
            releaseCallbackRefIfNeeded()
            AudioComponentInstanceDispose(unit)
            return false
        }

        guard AudioUnitInitialize(unit) == noErr else {
            logger.error("PLLSRCWriter: AudioUnitInitialize failed")
            releaseCallbackRefIfNeeded()
            AudioComponentInstanceDispose(unit)
            return false
        }
        guard AudioOutputUnitStart(unit) == noErr else {
            logger.error("PLLSRCWriter: AudioOutputUnitStart failed")
            releaseCallbackRefIfNeeded()
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            return false
        }

        audioUnit = unit
        logger.info("PLLSRCWriter: started for device \(self.config.deviceID)")
        return true
    }

    func stop() {
        guard let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        releaseCallbackRefIfNeeded()
    }

    private func releaseCallbackRefIfNeeded() {
        guard isCallbackRefRetained else { return }
        isCallbackRefRetained = false
        Unmanaged<PLLSRCWriter>.passUnretained(self).release()
    }
}