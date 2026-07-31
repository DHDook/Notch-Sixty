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

    let abl = UnsafeMutableAudioBufferListPointer(bufferList)

    for ch in 0..<channelCount {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        for i in 0..<frameCount {
            buffer[i] = amplitude
        }
        abl[ch].mNumberChannels = 1
        abl[ch].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        abl[ch].mData = UnsafeMutableRawPointer(buffer)
    }

    return bufferList.pointee
}

/// Frees the buffers allocated by createTestBufferList.
/// - Parameter bufferList: The AudioBufferList to free
func freeTestBufferList(bufferList: AudioBufferList) {
    var mutableBufferList = bufferList
    let abl = UnsafeMutableAudioBufferListPointer(&mutableBufferList)
    for i in 0..<Int(bufferList.mNumberBuffers) {
        if let mData = abl[i].mData {
            mData.deallocate()
        }
    }
}
