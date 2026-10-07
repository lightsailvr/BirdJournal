import Foundation
import Synchronization

/// The stretch while the app plays a reference clip (issue #41), and a tail after it: the microphone it listens
/// through hears the clip, and BirdNET would score the recording as that species. Shared by whoever plays (`begin()`
/// as a clip starts, `end()` as it finishes or is stopped) and every listening source (`SuppressedAudioSource`).
public final class AudioSuppression: Sendable {
    /// How long after a clip ends its sound may still arrive: the Bluetooth speaker's output delay plus the glasses'
    /// in-band audio stream's.
    public static let defaultTail: Duration = .seconds(1.5)

    private struct State {
        var holds = 0
        var releasedAt: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let tail: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(tail: Duration = defaultTail, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.tail = tail
        self.now = now
    }

    /// A clip starts playing.
    public func begin() {
        state.withLock { $0.holds += 1 }
    }

    /// A clip finished or was stopped; the tail starts once no clip is playing. An end with no begin is ignored.
    public func end() {
        let now = now()
        state.withLock { state in
            guard state.holds > 0 else { return }
            state.holds -= 1
            if state.holds == 0 { state.releasedAt = now }
        }
    }

    /// Whether audio arriving now may carry a clip.
    public var isSuppressing: Bool {
        let now = now()
        return state.withLock { state in
            if state.holds > 0 { return true }
            guard let releasedAt = state.releasedAt else { return false }
            return now < releasedAt + tail
        }
    }
}

/// Wraps a source so the chunks that arrive while `suppression` holds come out silent: same length and time, so the
/// engine's windows and the run's clock stay where they were, but nothing in them to hear.
public final class SuppressedAudioSource: AudioSource {
    private let base: any AudioSource
    private let suppression: AudioSuppression

    public init(_ base: any AudioSource, suppression: AudioSuppression) {
        self.base = base
        self.suppression = suppression
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let chunks = try await base.start()
        let (filtered, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1_024))
        let suppression = suppression
        let forwarding = Task {
            for await chunk in chunks {
                if suppression.isSuppressing {
                    var silent = chunk
                    silent.samples = [Float](repeating: 0, count: chunk.samples.count)
                    continuation.yield(silent)
                } else {
                    continuation.yield(chunk)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return filtered
    }

    public func stop() async {
        await base.stop()
    }
}
