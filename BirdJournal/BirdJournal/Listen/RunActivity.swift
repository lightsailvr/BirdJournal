@preconcurrency import ActivityKit
import Album
import Foundation
import Observation
import OSLog
import UIKit

extension RunSnapshot {
    /// The pure reading of a run (issue #150): what the Live Activity shows, from the coordinator's state and the run's hunt. A
    /// bird heard is a new patch waiting until an add would only tick an existing patch's count, so an add takes it off, and
    /// an undo puts it back.
    init(state: ListeningCoordinator.State, clockStart: Date?, pausedAt: Date? = nil, hunt: RunHunt, at coordinate: Coordinate?, sets: [CardSet]) {
        switch state {
        case .idle: phase = .idle
        case .starting: phase = .starting
        case .listening: phase = .listening
        case .interrupted, .resuming, .paused: phase = .paused
        case .stopping: phase = .stopping
        case .ended: phase = .ended
        }
        switch state {
        case .paused(let reason): pausedTitle = reason.phoneTitle
        case .interrupted: pausedTitle = "Checking the glasses"
        case .resuming: pausedTitle = "Picking up the glasses"
        default: pausedTitle = nil
        }
        startedAt = clockStart
        self.pausedAt = pausedAt
        birdsHeard = hunt.newPatches + hunt.alreadyHave
        newPatchesWaiting = hunt.newPatches
        setID = coordinate.flatMap { CardSet.containing($0, in: sets)?.id }
    }
}

extension ListeningCoordinator {
    /// The run as the Live Activity shows it.
    func snapshot(in collection: CardCollection) -> RunSnapshot {
        RunSnapshot(state: state, clockStart: clockStart, pausedAt: clock.pausedSince, hunt: hunt(in: collection), at: coordinate, sets: collection.sets)
    }
}

/// Where a run's snapshots go: ActivityKit on a phone, a double in tests.
@MainActor
protocol RunActivityHost: AnyObject {
    /// Whether there's an activity now: the system refuses one with the app out of front, or with them turned off.
    func begin(_ snapshot: RunSnapshot) -> Bool
    func update(_ snapshot: RunSnapshot)
    func end(_ snapshot: RunSnapshot)
    /// Ends activities no run in this process started: the app was killed part way through one.
    func endLeftovers()
}

/// Keeps one Live Activity in step with the run: it begins with the run, changes when the snapshot does, and ends with it.
@MainActor
final class RunActivityController {
    /// A heartbeat this often keeps a run's activity from going stale while the app is alive.
    static let heartbeat: Duration = .seconds(300)

    private let host: any RunActivityHost
    private var shown: RunSnapshot?
    private var heartbeatTask: Task<Void, Never>?

    init(host: any RunActivityHost) {
        self.host = host
    }

    /// What a new snapshot means for the activity.
    func apply(_ snapshot: RunSnapshot) {
        if snapshot.isRunning {
            if shown == nil {
                // Refused, the next change of the run asks again: a run started from behind a locked phone can still get one.
                guard host.begin(snapshot) else { return }
                startHeartbeat()
            } else if snapshot != shown {
                host.update(snapshot)
            }
            shown = snapshot
        } else if shown != nil {
            shown = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            host.end(snapshot)
        }
    }

    /// Follows the snapshot from now on, whatever screen is up and whether or not the app is in front: a run goes on behind
    /// a locked phone, where no view is drawn.
    func follow(_ read: @escaping @MainActor () -> RunSnapshot) {
        host.endLeftovers()
        observe(read)
    }

    private func observe(_ read: @escaping @MainActor () -> RunSnapshot) {
        let snapshot = withObservationTracking(read) { [weak self] in
            Task { @MainActor in self?.observe(read) }
        }
        apply(snapshot)
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                guard !Task.isCancelled, let self, let shown = self.shown else { return }
                self.host.update(shown)
            }
        }
    }
}

/// The real Live Activity. With no word from the app for a while it shows as stale, since an app killed mid-run can't end it;
/// the next launch does.
@MainActor
final class ActivityKitRunHost: RunActivityHost {
    private static let staleAfter: TimeInterval = 900
    private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "listening")
    private var activity: Activity<RunActivityAttributes>?

    private func content(_ snapshot: RunSnapshot) -> ActivityContent<RunSnapshot> {
        ActivityContent(state: snapshot, staleDate: .now.addingTimeInterval(Self.staleAfter))
    }

    func begin(_ snapshot: RunSnapshot) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        do {
            activity = try Activity.request(attributes: RunActivityAttributes(), content: content(snapshot))
            return true
        } catch {
            log.error("no Live Activity for this run yet: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func update(_ snapshot: RunSnapshot) {
        guard let activity else { return }
        let content = content(snapshot)
        Task { await activity.update(content) }
    }

    func end(_ snapshot: RunSnapshot) {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: snapshot, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    func endLeftovers() {
        for leftover in Activity<RunActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
