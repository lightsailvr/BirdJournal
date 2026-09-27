import AVFAudio
import Foundation
import Identification

/// Audio from the phone's own microphone, for listening without glasses. Delivers the same mono chunks as
/// `GlassesAudioSource`, at the input's native rate, with presentation times on the host clock.
@MainActor
final class PhoneMicAudioSource: AudioSource {
    enum StartError: LocalizedError {
        case permissionDenied

        var errorDescription: String? { "Microphone access was not granted. Allow it in Settings > BirdJournal." }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() async throws -> AsyncStream<AudioChunk> {
        guard await AVAudioApplication.requestRecordPermission() else { throw StartError.permissionDenied }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true)

        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1_024))
        self.continuation = continuation
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4_096, format: input.outputFormat(forBus: 0), block: Self.tap(yieldingTo: continuation))
        try engine.start()
        return chunks
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        continuation?.finish()
        continuation = nil
    }

    /// Built outside the main actor: the tap runs on the audio render thread.
    private nonisolated static func tap(yieldingTo continuation: AsyncStream<AudioChunk>.Continuation) -> AVAudioNodeTapBlock {
        { buffer, time in
            let presentationTime = AVAudioTime.seconds(forHostTime: time.hostTime)
            if let chunk = AudioChunk(buffer: buffer, presentationTime: presentationTime) {
                continuation.yield(chunk)
            }
        }
    }
}
