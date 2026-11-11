import Album
import Foundation
import Observation

/// Where the phone is while the camera is open with no run under way (issue #191, of #185). A run reads its own place for
/// as long as it listens, and a photo taken on one is recorded there; with no run, this reads it for as long as the camera
/// is open, so the shutter has the fix of that moment. The first read asks for when-in-use permission, as Start listening
/// does. Nothing is read before the camera opens, and the read ends when it closes.
@MainActor
@Observable
final class CapturePlace {
    /// What the read has delivered since the camera opened; `.unknown` while it is closed.
    private(set) var state = ListeningSession.LocationState.unknown

    @ObservationIgnored private let location: any LocationProvider
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// Photos taken before the first answer, waiting for it.
    @ObservationIgnored private var waiting: [AsyncStream<Coordinate?>.Continuation] = []
    /// The camera has closed with a photo still waiting: the read goes on to its first answer, and no further.
    @ObservationIgnored private var isClosing = false

    init(location: any LocationProvider) {
        self.location = location
    }

    /// The latest fix, as the album records one; nil until there is one, and when location is refused or not to be had.
    var coordinate: Coordinate? {
        guard case .settled(.fix(let latitude, let longitude, let accuracy, _)) = state else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude, accuracy: accuracy)
    }

    /// The camera has opened: the place is read from now until `close`.
    func open() {
        isClosing = false
        guard reading == nil else { return }
        state = .requesting
        let fixes = location.fixes()
        reading = Task { [weak self] in
            for await fix in fixes {
                guard let self, !Task.isCancelled else { return }
                self.note(fix)
                if self.isClosing { break }
            }
            guard let self, !Task.isCancelled else { return }
            // The stream ended: a denial, or Core Location giving up.
            if self.state == .requesting { self.note(.unavailable) }
            self.reading = nil
            if self.isClosing { self.state = .unknown }
        }
    }

    /// The camera has closed. The read ends, unless a photo taken before its first answer is waiting for that answer.
    func close() {
        if waiting.isEmpty {
            reading?.cancel()
            reading = nil
            state = .unknown
        } else {
            isClosing = true
        }
    }

    /// The place once the read has its first answer, as a stream of that one element: a fix, or nil for a denial or no fix
    /// in time. At once when the read has answered, or when nothing is being read. Whoever asks is waiting from this call
    /// on, not from when they first read the stream: a camera closed in between still gets them their answer.
    func firstAnswer() -> AsyncStream<Coordinate?> {
        let (answer, continuation) = AsyncStream.makeStream(of: Coordinate?.self)
        if state == .requesting {
            waiting.append(continuation)
        } else {
            continuation.yield(coordinate)
            continuation.finish()
        }
        return answer
    }

    /// As a run keeps its place: no fix after a fix keeps the earlier one.
    private func note(_ fix: LocationFix) {
        if case .unavailable = fix, case .settled(.fix) = state {
            // Keep the earlier fix.
        } else {
            state = .settled(fix)
        }
        let answered = waiting
        waiting = []
        for continuation in answered {
            continuation.yield(coordinate)
            continuation.finish()
        }
    }
}
