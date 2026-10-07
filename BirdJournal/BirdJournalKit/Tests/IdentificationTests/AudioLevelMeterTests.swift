import Foundation
import Testing
@testable import Identification

// Issue #28: the phone's waveform follows the live input's level.
@Suite("Audio level meter")
struct AudioLevelMeterTests {
    @Test("silence is zero, a full-scale sine has RMS 1/√2 and peak 1, and the display value sits between")
    func levels() {
        #expect(AudioLevelMeter.level(of: []) == .silence)
        #expect(AudioLevelMeter.level(of: [Float](repeating: 0, count: 480)) == .silence)

        let sine = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let level = AudioLevelMeter.level(of: sine)
        #expect(abs(level.rms - 0.7071) < 0.001)
        #expect(abs(level.peak - 1) < 0.001)
        #expect(level.displayValue > 0.9)

        let quiet = AudioLevelMeter.level(of: sine.map { $0 * 0.01 })  // about -43 dBFS
        #expect(quiet.displayValue > 0.35 && quiet.displayValue < 0.5)
        #expect(AudioLevel(rms: 0.1, peak: 0.1).displayValue == 1, "-20 dBFS is full height")
        #expect(AudioLevel(rms: 0.0001, peak: 0.0001).displayValue == 0, "under -60 dBFS reads as silence")
        #expect(AudioLevel.silence.displayValue == 0)
    }

    @Test("a metered source passes every chunk through and reports each chunk's level, then silence when the source ends")
    func meteredSource() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let base = StreamAudioSource(stream: stream)
        let levels = LockedList<AudioLevel>()
        let source = MeteredAudioSource(base) { levels.append($0) }

        let chunks = try await source.start()
        continuation.yield(AudioChunk(samples: [0.5, -0.5, 0.5, -0.5], sampleRate: 4, presentationTime: 0))
        continuation.yield(AudioChunk(samples: [0, 0], sampleRate: 4, presentationTime: 1))
        continuation.finish()

        var received: [AudioChunk] = []
        for await chunk in chunks { received.append(chunk) }
        #expect(received.map(\.presentationTime) == [0, 1])
        #expect(received.map(\.samples.count) == [4, 2])
        #expect(levels.values.map(\.rms) == [0.5, 0, 0])
        #expect(levels.values.last == .silence)
        await source.stop()
        #expect(base.stopped.values == [true])
    }
}

/// Hands out a stream the test feeds.
final class StreamAudioSource: AudioSource {
    let stream: AsyncStream<AudioChunk>
    let stopped = LockedList<Bool>()

    init(stream: AsyncStream<AudioChunk>) {
        self.stream = stream
    }

    func start() async throws -> AsyncStream<AudioChunk> { stream }
    func stop() async { stopped.append(true) }
}

final class LockedList<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    var values: [Element] { lock.withLock { storage } }
}
