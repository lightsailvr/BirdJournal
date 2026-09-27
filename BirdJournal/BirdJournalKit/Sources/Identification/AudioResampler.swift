import AVFAudio

public enum ResampleError: Error {
    case unsupportedRate(Int)
    case converterUnavailable(from: Int, to: Int)
    case conversionFailed(any Error)
}

/// Converts chunks from a source's native rate to the model rate, keeping the converter's filter state across
/// chunks so the output is continuous. One instance serves one source; it is not thread-safe.
public final class AudioResampler {
    public let outputRate: Int

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    public init(outputRate: Int = 32_000) {
        precondition(outputRate > 0, "outputRate must be positive")
        self.outputRate = outputRate
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(outputRate), channels: 1, interleaved: false)!
    }

    /// Returns the chunk's samples at the output rate. Chunks already at that rate pass through untouched.
    public func resample(_ chunk: AudioChunk) throws -> [Float] {
        guard chunk.sampleRate != outputRate else { return chunk.samples }
        guard !chunk.samples.isEmpty else { return [] }
        let converter = try converter(forInputRate: chunk.sampleRate)

        let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count))!
        chunk.samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        input.frameLength = AVAudioFrameCount(chunk.samples.count)

        let ratio = Double(outputRate) / Double(chunk.sampleRate)
        let capacity = AVAudioFrameCount((Double(chunk.samples.count) * ratio).rounded(.up)) + 64
        return try convert(with: converter, capacity: capacity, input: input, trailingStatus: .noDataNow)
    }

    /// Drains the samples the converter's filter still holds once the source has ended, and resets it so the next
    /// chunk starts a fresh stream. Returns nothing if no conversion happened.
    public func flush() throws -> [Float] {
        guard let converter else { return [] }
        defer { converter.reset() }
        return try convert(with: converter, capacity: 256, input: nil, trailingStatus: .endOfStream)
    }

    private func convert(with converter: AVAudioConverter, capacity: AVAudioFrameCount, input: AVAudioPCMBuffer?, trailingStatus: AVAudioConverterInputStatus) throws -> [Float] {
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
        var pending = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let next = pending else {
                outStatus.pointee = trailingStatus
                return nil
            }
            pending = nil
            outStatus.pointee = .haveData
            return next
        }
        if let error { throw ResampleError.conversionFailed(error) }
        guard status != .error else { throw ResampleError.converterUnavailable(from: Int(converter.inputFormat.sampleRate), to: outputRate) }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    private func converter(forInputRate rate: Int) throws -> AVAudioConverter {
        if let converter, Int(converter.inputFormat.sampleRate) == rate { return converter }
        guard rate > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false) else {
            throw ResampleError.unsupportedRate(rate)
        }
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw ResampleError.converterUnavailable(from: rate, to: outputRate)
        }
        self.converter = converter
        inputFormat = format
        return converter
    }
}
