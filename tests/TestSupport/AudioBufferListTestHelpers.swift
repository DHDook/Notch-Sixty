// AudioBufferListTestHelpers.swift
// Shared helper functions for creating and freeing test AudioBufferList structures

import CoreAudio
import AudioToolbox

/// Creates a test AudioBufferList with the specified number of channels and frame count.
/// The buffers are filled with the specified amplitude.
/// - Parameters:
///   - channelCount: Number of audio channels
///   - frameCount: Number of frames per channel
///   - amplitude: Amplitude value to fill the buffers with
/// - Returns: An AudioBufferList structure with allocated buffers
func createTestBufferList(channelCount: Int, frameCount: Int, amplitude: Float) -> AudioBufferList {
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

/// Frees the buffers allocated by createTestBufferList.
/// - Parameter bufferList: The AudioBufferList to free
func freeTestBufferList(bufferList: AudioBufferList) {
    for i in 0..<Int(bufferList.mNumberBuffers) {
        if let mData = bufferList.mBuffers[i].mData {
            mData.deallocate()
        }
    }
}
