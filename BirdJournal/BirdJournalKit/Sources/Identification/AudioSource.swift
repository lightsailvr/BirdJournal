import AVFAudio

/// A block of mono PCM audio as every `AudioSource` delivers it: Float samples in [-1, 1] at the source's native
/// rate. The engine resamples to the model rate; sources never do.
public struct AudioChunk: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Int
    /// Presentation time in seconds on the source's own clock. Only differences between chunks of one source
    /// are meaningful.
    public var presentationTime: Double

    public init(samples: [Float], sampleRate: Int, presentationTime: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.presentationTime = presentationTime
    }

    /// Length of the chunk in seconds.
    public var duration: Double { Double(samples.count) / Double(sampleRate) }
}

extension AudioChunk {
    /// Copies a Float32 or Int16 buffer of any channel count and layout into a mono chunk, averaging channels.
    /// Returns nil for other sample formats.
    public init?(buffer: AVAudioPCMBuffer, presentationTime: Double) {
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard channels > 0 else { return nil }

        let mono: [Float]
        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let planes = buffer.floatChannelData else { return nil }
            mono = Self.downmix(planes, frames: frames, channels: channels, interleaved: format.isInterleaved) { $0 }
        case .pcmFormatInt16:
            guard let planes = buffer.int16ChannelData else { return nil }
            mono = Self.downmix(planes, frames: frames, channels: channels, interleaved: format.isInterleaved) { Float($0) / 32_768 }
        default:
            return nil
        }

        self.init(samples: mono, sampleRate: Int(format.sampleRate), presentationTime: presentationTime)
    }

    /// Averages channels into one. Interleaved buffers hold every channel in plane 0; non-interleaved buffers
    /// hold one plane per channel.
    private static func downmix<Sample>(
        _ planes: UnsafePointer<UnsafeMutablePointer<Sample>>,
        frames: Int,
        channels: Int,
        interleaved: Bool,
        toFloat: (Sample) -> Float
    ) -> [Float] {
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for channel in 0..<channels {
            let plane = planes[interleaved ? 0 : channel]
            for frame in 0..<frames {
                mono[frame] += toFloat(plane[interleaved ? frame * channels + channel : frame]) * scale
            }
        }
        return mono
    }
}

/// Where PCM audio comes from: the glasses camera stream, the phone microphone, or a WAV file in tests
/// (DECISIONS.md, "Audio and identification"). `start()` returns the chunk stream; it finishes after `stop()`
/// or when the source ends.
public protocol AudioSource: Sendable {
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}
