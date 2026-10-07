import Foundation
import Synchronization
import Testing
@testable import Identification

// Issue #41: a reference clip the app plays reaches the microphone it listens through, so the audio heard while one
// plays, and for a tail after it, is silenced before the engine scores it.
@Suite("Audio suppression")
struct AudioSuppressionTests {
    @Test("suppressing from the first begin until the tail after the last end; an unmatched end changes nothing")
    func window() {
        let clock = TestClock()
        let suppression = AudioSuppression(tail: .seconds(1.5), now: clock.now)
        #expect(!suppression.isSuppressing)

        suppression.end()
        #expect(!suppression.isSuppressing, "an end with no begin does not start a tail")

        suppression.begin()
        #expect(suppression.isSuppressing)
        clock.advance(.seconds(30))
        #expect(suppression.isSuppressing, "held for as long as the clip plays")

        suppression.begin()  // the call starts as the song is stopped
        suppression.end()
        #expect(suppression.isSuppressing, "still held by the other clip")
        clock.advance(.seconds(5))
        #expect(suppression.isSuppressing)

        suppression.end()
        #expect(suppression.isSuppressing, "the tail covers the speaker's and the stream's delay")
        clock.advance(.seconds(1.4))
        #expect(suppression.isSuppressing)
        clock.advance(.seconds(0.2))
        #expect(!suppression.isSuppressing)
    }

    @Test("a suppressed source passes chunks through, silences the ones that arrive while suppressing and keeps their length and time")
    func silencesWhileSuppressing() async throws {
        let clock = TestClock()
        let suppression = AudioSuppression(tail: .seconds(1), now: clock.now)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let base = StreamAudioSource(stream: stream)
        let source = SuppressedAudioSource(base, suppression: suppression)

        var chunks = try await source.start().makeAsyncIterator()
        let loud = [Float](repeating: 0.5, count: 4)

        continuation.yield(AudioChunk(samples: loud, sampleRate: 4, presentationTime: 0))
        #expect(await chunks.next()?.samples == loud)

        suppression.begin()
        continuation.yield(AudioChunk(samples: loud, sampleRate: 4, presentationTime: 1))
        let held = await chunks.next()
        #expect(held?.samples == [0, 0, 0, 0])
        #expect(held?.presentationTime == 1)

        suppression.end()
        clock.advance(.seconds(0.5))
        continuation.yield(AudioChunk(samples: loud, sampleRate: 4, presentationTime: 2))
        #expect(await chunks.next()?.samples == [0, 0, 0, 0], "inside the tail")

        clock.advance(.seconds(0.6))
        continuation.yield(AudioChunk(samples: loud, sampleRate: 4, presentationTime: 3))
        #expect(await chunks.next()?.samples == loud)

        continuation.finish()
        #expect(await chunks.next() == nil)
        await source.stop()
        #expect(base.stopped.values == [true])
    }

    @Test("a clip played through a whole run produces no candidate, where the same audio unsuppressed does")
    func clipDuringARunProducesNothing() async throws {
        let engine = IdentificationEngine(model: LoudnessBirdModel(), occurrenceModel: FixedOccurrence(["Haemorhous mexicanus": 1]))
        let clip = try Fixtures.url("synthetic-chirps-44k1.wav")

        let heard = try await collect(engine.identify(WAVFileAudioSource(url: clip), in: nil))
        let heardStack = heard.compactMap { if case .stack(let stack) = $0 { stack } else { nil } }.last
        #expect(heardStack?.candidates.map(\.species.commonName) == ["House Finch"], "the control: the clip alone is a finch")

        let suppression = AudioSuppression()
        suppression.begin()
        let playing = try await collect(engine.identify(SuppressedAudioSource(WAVFileAudioSource(url: clip), suppression: suppression), in: nil))
        suppression.end()
        let windows = playing.filter { if case .window = $0 { true } else { false } }
        #expect(!windows.isEmpty, "the windows are still scored, on silence")
        #expect(!playing.contains { if case .stack = $0 { true } else { false } })
    }

    private func collect(_ stream: AsyncThrowingStream<IdentificationEvent, any Error>) async throws -> [IdentificationEvent] {
        var events: [IdentificationEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let start = ContinuousClock.now
    private let offset = Mutex(Duration.zero)

    var now: @Sendable () -> ContinuousClock.Instant {
        { self.start + self.offset.withLock { $0 } }
    }

    func advance(_ duration: Duration) {
        offset.withLock { $0 += duration }
    }
}
