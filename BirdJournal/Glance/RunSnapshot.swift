import ActivityKit
import Foundation

/// What a run looks like from outside the app (issue #150): a small value the Live Activity draws and nothing else, so what
/// it shows is tested without ActivityKit. The app derives it from `ListeningCoordinator`'s state; this file is built into
/// the app and the widget extension, which can't see the coordinator.
nonisolated struct RunSnapshot: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable {
        case idle, starting, listening, paused, stopping, ended
    }

    var phase: Phase
    /// When the run started listening; nil until it has.
    var startedAt: Date?
    var birdsHeard: Int
    /// Birds heard whose add would sew a new patch here.
    var newPatchesWaiting: Int
    /// What the run is waiting for, while it's paused: "Paused: glasses off".
    var pausedTitle: String?
    /// The set of the run's place, for the edition's tint; nil outside every set or before a fix.
    var setID: String?

    static let idle = RunSnapshot(phase: .idle, startedAt: nil, birdsHeard: 0, newPatchesWaiting: 0)

    /// A run is under way, so there is an activity to show.
    var isRunning: Bool {
        switch phase {
        case .starting, .listening, .paused, .stopping: true
        case .idle, .ended: false
        }
    }

    /// What the run is doing, in a word or two.
    var statusText: String {
        switch phase {
        case .idle, .ended: "Run ended"
        case .starting: "Starting"
        case .listening: "Listening"
        case .paused: pausedTitle ?? "Paused"
        case .stopping: "Stopping"
        }
    }

    /// "1 bird heard", "3 birds heard".
    var birdsHeardText: String {
        "\(birdsHeard) \(birdsHeard == 1 ? "bird" : "birds") heard"
    }

    /// "1 new patch waiting"; nil with none, when the line says nothing.
    var newPatchesText: String? {
        guard newPatchesWaiting > 0 else { return nil }
        return "\(newPatchesWaiting) new \(newPatchesWaiting == 1 ? "patch" : "patches") waiting"
    }

    /// What VoiceOver reads for the run.
    var spokenText: String {
        [statusText, birdsHeardText, newPatchesText].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The run's Live Activity: its source is fixed for the run, and everything that changes is the snapshot.
nonisolated struct RunActivityAttributes: ActivityAttributes {
    typealias ContentState = RunSnapshot

    /// `ListeningCoordinator.Source`'s raw value.
    var source: String
}
