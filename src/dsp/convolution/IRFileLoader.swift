//
//  IRFileLoader.swift
//  Equaliser
//
//  Loads impulse response files (WAV/AIFF) for convolution.
//

import Foundation
import AVFoundation

/// Result structure for loaded impulse response.
struct IRLoadResult {
    let leftSamples: [Float]
    let rightSamples: [Float]
    let displayName: String
}

/// Loads impulse response files from disk.
enum IRFileLoader {
    
    /// Loads an impulse response from a WAV or AIFF file.
    /// - Parameters:
    ///   - url: The file URL to load from.
    ///   - targetSampleRate: The target sample rate for resampling if needed.
    /// - Returns: An IRLoadResult containing the left/right samples and display name.
    /// - Throws: An error if the file cannot be loaded or parsed.
    static func load(url: URL, targetSampleRate: Double) throws -> IRLoadResult {
        // Ensure we have security scope access
        let hadAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hadAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Read the audio file
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        
        guard format.sampleRate <= 192_000 else {
            throw IRError.sampleRateTooHigh(format.sampleRate)
        }
        
        let frameCount = UInt32(file.length)
        guard frameCount > 0 else {
            throw IRError.emptyFile
        }
        
        // Limit IR length to 30 seconds at target sample rate
        let maxFrames = Int(targetSampleRate * 30.0)
        let framesToRead = Int(frameCount) > maxFrames ? maxFrames : Int(frameCount)
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(framesToRead)
        ) else {
            throw IRError.bufferCreationFailed
        }
        
        try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
        
        guard let channelData = buffer.floatChannelData else {
            throw IRError.noChannelData
        }
        
        let channelCount = Int(format.channelCount)
        var leftSamples: [Float]
        var rightSamples: [Float]
        
        if channelCount == 1 {
            // Mono IR - duplicate to both channels
            leftSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            rightSamples = leftSamples
        } else if channelCount == 2 {
            // Stereo IR
            leftSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            rightSamples = Array(UnsafeBufferPointer(start: channelData[1], count: Int(buffer.frameLength)))
        } else {
            // Multi-channel - use first two channels
            leftSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            rightSamples = Array(UnsafeBufferPointer(start: channelData[1], count: Int(buffer.frameLength)))
        }
        
        // Resample if needed
        if abs(format.sampleRate - targetSampleRate) > 1.0 {
            (leftSamples, rightSamples) = try resample(
                left: leftSamples,
                right: rightSamples,
                fromRate: format.sampleRate,
                toRate: targetSampleRate
            )
        }
        
        let displayName = url.deletingPathExtension().lastPathComponent
        
        return IRLoadResult(
            leftSamples: leftSamples,
            rightSamples: rightSamples,
            displayName: displayName
        )
    }
    
    /// Resamples audio from one sample rate to another using AVAudioConverter.
    private static func resample(
        left: [Float],
        right: [Float],
        fromRate: Double,
        toRate: Double
    ) throws -> (left: [Float], right: [Float]) {
        let isStereo = true
        let inFormat  = AVAudioFormat(standardFormatWithSampleRate: fromRate, channels: 2)!
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: toRate,   channels: 2)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw IRError.unsupportedFormat
        }
        let inFrames  = AVAudioFrameCount(left.count)
        let outFrames = AVAudioFrameCount(Double(inFrames) * toRate / fromRate + 1)
        guard let inBuf  = AVAudioPCMBuffer(pcmFormat: inFormat,  frameCapacity: inFrames),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames)
        else { throw IRError.bufferCreationFailed }
        inBuf.frameLength = inFrames
        left.withUnsafeBufferPointer  { inBuf.floatChannelData![0].initialize(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { inBuf.floatChannelData![1].initialize(from: $0.baseAddress!, count: right.count) }
        var inputConsumed = false
        let status = converter.convert(to: outBuf, error: nil) { _, outStatus in
            if inputConsumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inBuf
        }
        guard status != .error else { throw IRError.unsupportedFormat }
        let n = Int(outBuf.frameLength)
        let leftOut  = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
        let rightOut = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![1], count: n))
        return (leftOut, rightOut)
    }
    
    enum IRError: LocalizedError {
        case sampleRateTooHigh(Double)
        case emptyFile
        case bufferCreationFailed
        case noChannelData
        case unsupportedFormat
        
        var errorDescription: String? {
            switch self {
            case .sampleRateTooHigh(let rate):
                return "Sample rate \(Int(rate)) Hz is too high (max 192 kHz)"
            case .emptyFile:
                return "Impulse response file is empty"
            case .bufferCreationFailed:
                return "Failed to create audio buffer"
            case .noChannelData:
                return "No audio channel data found"
            case .unsupportedFormat:
                return "Unsupported audio format"
            }
        }
    }
}
