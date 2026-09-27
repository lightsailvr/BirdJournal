import AVFAudio
import Foundation
import Synchronization

/// Plays a WAV (or any AVAudioFile-readable) file into the engine as chunks at the file's own rate, for tests and
/// for replaying labeled recordings. Multi-channel files are averaged to mono.
public final class WAVFileAudioSource: AudioSource {
    public enum SourceError: Error {
        case alreadyStarted
    }

    public let url: URL
    public let chunkFrames: Int

    private enum State {
        case idle
        case starting
        case running(Task<Void, Never>)
    }

    private let state = Mutex(State.idle)

    public init(url: URL, chunkFrames: Int = 4_096) {
        precondition(chunkFrames > 0, "chunkFrames must be positive")
        self.url = url
        self.chunkFrames = chunkFrames
    }

    /// Opens the file (throwing if it cannot be read) and streams it; the stream finishes at end of file or on `stop()`.
    public func start() async throws -> AsyncStream<AudioChunk> {
        let claimed = state.withLock { state -> Bool in
            guard case .idle = state else { return false }
            state = .starting
            return true
        }
        guard claimed else { throw SourceError.alreadyStarted }
        do {
            _ = try AVAudioFile(forReading: url)
        } catch {
            state.withLock { $0 = .idle }
            throw error
        }
        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let reader = Task.detached(priority: .utility) { [url, chunkFrames] in
            defer { continuation.finish() }
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)) else { return }
            while !Task.isCancelled, file.framePosition < file.length {
                let position = file.framePosition
                guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(chunkFrames))) != nil, buffer.frameLength > 0 else { return }
                guard let chunk = AudioChunk(buffer: buffer, presentationTime: Double(position) / format.sampleRate) else { return }
                continuation.yield(chunk)
            }
        }
        state.withLock { $0 = .running(reader) }
        return chunks
    }

    public func stop() async {
        let reader = state.withLock { state -> Task<Void, Never>? in
            defer { state = .idle }
            if case .running(let task) = state { return task }
            return nil
        }
        reader?.cancel()
        await reader?.value
    }
}
