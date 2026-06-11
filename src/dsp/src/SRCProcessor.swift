import AVFoundation

/// Sample Rate Conversion (SRC) processor using AVAudioConverter.
///
/// Wraps AVAudioConverter to perform high-quality sample rate conversion
/// between different audio formats. Used for upsampling before DSP processing
/// and downsampling back to the output sample rate.
final class SRCProcessor: @unchecked Sendable {

    // MARK: - Properties

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    // MARK: - Initialization

    /// Creates a new SRC processor with the specified input and output formats.
    /// - Parameters:
    ///   - inputFormat: The input audio format.
    ///   - outputFormat: The desired output audio format.
    /// - Returns: nil if the converter cannot be created.
    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    // MARK: - Processing

    /// Performs sample rate conversion on the input buffer.
    /// - Parameter inputBuffer: The input PCM buffer to convert.
    /// - Returns: The converted buffer, or nil if conversion fails.
    func process(inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard inputBuffer.frameLength > 0 else {
            return nil
        }

        // Calculate output frame count based on sample rate ratio
        let sampleRateRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * sampleRateRatio))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            return nil
        }

        var error: NSError?

        let status = converter.convert(
            to: outputBuffer,
            error: &error
        ) { inBuffer, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status == .haveData && error == nil else {
            return nil
        }

        return outputBuffer
    }
}
