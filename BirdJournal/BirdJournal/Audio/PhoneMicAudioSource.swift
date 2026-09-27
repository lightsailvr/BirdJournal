import AVFAudio
import Foundation
import Identification
import Synchronization

/// Audio from the phone's own microphone, for listening without glasses. Delivers the same mono chunks as
/// `GlassesAudioSource`, at the input's native rate, with presentation times on the host clock.
///
/// Core Audio activates the session and initializes the input unit with blocking calls (the runtime flags
/// `setActive` on the main thread as a hang risk, and the simulator deadlocked in `inputNode` there), so setup and
/// teardown run on a detached task and the engine lives behind a lock. Single use: create one per listening run.
nonisolated final class PhoneMicAudioSource: AudioSource {
    nonisolated enum StartError: LocalizedError {
        case permissionDenied

        var errorDescription: String? { "Microphone access was not granted. Allow it in Settings > BirdJournal." }
    }

    private let engine = Mutex<AVAudioEngine?>(nil)
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)

    func start() async throws -> AsyncStream<AudioChunk> {
        guard await AVAudioApplication.requestRecordPermission() else { throw StartError.permissionDenied }

        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1_024))
        self.continuation.withLock { $0 = continuation }
        try await Task.detached(priority: .userInitiated) { [self] in
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)

            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            input.installTap(onBus: 0, bufferSize: 4_096, format: input.outputFormat(forBus: 0), block: Self.tap(yieldingTo: continuation))
            try audioEngine.start()
            engine.withLock { $0 = audioEngine }
        }.value
        return chunks
    }

    func stop() async {
        await Task.detached { [self] in
            engine.withLock { audioEngine in
                audioEngine?.inputNode.removeTap(onBus: 0)
                audioEngine?.stop()
                audioEngine = nil
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }.value
        continuation.withLock {
            $0?.finish()
            $0 = nil
        }
    }

    /// The tap runs on the audio render thread.
    private static func tap(yieldingTo continuation: AsyncStream<AudioChunk>.Continuation) -> AVAudioNodeTapBlock {
        { buffer, time in
            let presentationTime = AVAudioTime.seconds(forHostTime: time.hostTime)
            if let chunk = AudioChunk(buffer: buffer, presentationTime: presentationTime) {
                continuation.yield(chunk)
            }
        }
    }
}
