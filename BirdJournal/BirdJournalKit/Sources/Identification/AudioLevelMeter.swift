import Foundation

/// How loud one chunk of audio was: its RMS and its peak, both in [0, 1]. What the phone's waveform shows while a run
/// listens (issue #28); it is a picture of the live input, not of anything saved.
public struct AudioLevel: Sendable, Equatable {
    public var rms: Float
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silence = AudioLevel(rms: 0, peak: 0)

    /// The level on a decibel scale mapped to [0, 1]: silence and anything under -60 dBFS is 0, -20 dBFS and above is
    /// 1. A quiet dawn chorus at -45 dBFS sits around a third of the way up rather than at the bottom, where linear
    /// RMS would put it.
    public var displayValue: Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 60) / 40, 0), 1)
    }
}

public enum AudioLevelMeter {
    /// The level of `samples`; an empty chunk is silence.
    public static func level(of samples: [Float]) -> AudioLevel {
        guard !samples.isEmpty else { return .silence }
        var sumOfSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        return AudioLevel(rms: min((sumOfSquares / Float(samples.count)).squareRoot(), 1), peak: min(peak, 1))
    }

    public static func level(of chunk: AudioChunk) -> AudioLevel {
        level(of: chunk.samples)
    }
}

/// An audio source that passes another's chunks through unchanged and reports each one's level as it goes by. The
/// engine reads the chunks as before; the screen reads the levels.
public final class MeteredAudioSource: AudioSource {
    private let base: any AudioSource
    private let onLevel: @Sendable (AudioLevel) -> Void

    public init(_ base: any AudioSource, onLevel: @escaping @Sendable (AudioLevel) -> Void) {
        self.base = base
        self.onLevel = onLevel
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let chunks = try await base.start()
        let (metered, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1_024))
        let onLevel = onLevel
        let forwarding = Task {
            for await chunk in chunks {
                onLevel(AudioLevelMeter.level(of: chunk))
                continuation.yield(chunk)
            }
            onLevel(.silence)
            continuation.finish()
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return metered
    }

    public func stop() async {
        await base.stop()
    }
}
