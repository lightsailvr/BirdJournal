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

    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(url: URL, chunkFrames: Int = 4_096) {
        precondition(chunkFrames > 0, "chunkFrames must be positive")
        self.url = url
        self.chunkFrames = chunkFrames
    }

    /// Opens the file (throwing if it cannot be read) and streams it; the stream finishes at end of file or on `stop()`.
    public func start() async throws -> AsyncStream<AudioChunk> {
        _ = try AVAudioFile(forReading: url)
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
        let started = task.withLock { current -> Bool in
            guard current == nil else { return false }
            current = reader
            return true
        }
        guard started else {
            reader.cancel()
            throw SourceError.alreadyStarted
        }
        return chunks
    }

    public func stop() async {
        let reader = task.withLock { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        reader?.cancel()
        await reader?.value
    }
}
