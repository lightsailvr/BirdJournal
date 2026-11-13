import AVFoundation
import OSLog

/// The sound of a photo taken from the lens (2026-11-12): a chime when listening is about to come back, which the
/// wearer has no other way to know with the phone in a pocket. There is no shutter sound: the glasses' photo mode
/// makes none, and the phone only knows the glasses have the photo two to four seconds after the tap, which is too
/// late to mean the shutter (the maintainer's call). The lens marks the tap instead (`LensElement.shutter`).
nonisolated enum CaptureCue: Sendable {
    case listening
}

@MainActor
protocol CaptureCuePlaying: AnyObject {
    /// Plays `cue` and returns when it is over.
    func play(_ cue: CaptureCue) async
}

/// The cues through the phone's audio route, which is the glasses' speakers while they are connected, in the session
/// reference clips use, so music the birder had on comes back after. The sound is made here, not bundled: two rising
/// notes.
@MainActor
final class SystemCaptureCues: CaptureCuePlaying {
    private nonisolated static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "sounds")
    private let session = SystemPlaybackAudioSession()
    private var player: AVAudioPlayer?
    private let chime = CaptureCueSound.wav(CaptureCueSound.chime())

    func play(_ cue: CaptureCue) async {
        do {
            try await session.activate()
            let player: AVAudioPlayer
            switch cue {
            case .listening: player = try AVAudioPlayer(data: chime)
            }
            self.player = player
            guard player.play() else { throw AVSoundPlayer.PlayError.didNotStart }
            try? await Task.sleep(for: .seconds(player.duration + 0.15))
        } catch {
            Self.logger.error("capture cue not played: \(error.localizedDescription, privacy: .public)")
        }
        player = nil
        session.deactivate()
    }
}

/// The cues' samples, mono at 44.1 kHz.
nonisolated enum CaptureCueSound {
    static let sampleRate = 44_100.0

    /// Two notes rising a fourth, soft, each with a quick start and a slow end.
    static func chime() -> [Float] {
        func note(_ frequency: Double, _ seconds: Double) -> [Float] {
            (0..<Int(seconds * sampleRate)).map { index in
                let time = Double(index) / sampleRate
                let envelope = min(time / 0.008, 1) * exp(-time / 0.09)
                return Float(0.35 * envelope * sin(2 * .pi * frequency * time))
            }
        }
        return note(659.26, 0.16) + note(880, 0.3) + silence(0.02)
    }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// `samples` as a 16-bit mono WAV file.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
