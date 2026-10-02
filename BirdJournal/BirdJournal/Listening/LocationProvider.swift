import CoreLocation
import Foundation
import Synchronization

/// What the location stream delivers.
nonisolated enum LocationFix: Equatable, Sendable {
    /// A fix with its horizontal accuracy in metres.
    case fix(latitude: Double, longitude: Double, accuracy: Double, at: Date)
    /// The user declined when-in-use permission, or it is restricted. Identification carries on without the geo
    /// filter (issue #6).
    case denied
    /// Permission is fine but no fix arrived in time.
    case unavailable
}

/// The location seam for a listening session (issue #44): a stream of fixes for as long as the run reads it. The
/// first element settles Start (a fix, a denial, or `.unavailable` once the wait runs out); later elements are the
/// birder moving, so every add records where it was made. DECISIONS.md: when-in-use permission, live updates held
/// through the background for the whole run.
protocol LocationProvider {
    /// Asks for when-in-use permission the first time (the system prompts once) and yields fixes until the stream
    /// is dropped.
    func fixes() -> AsyncStream<LocationFix>
}

/// Core Location through `CLLocationUpdate.liveUpdates`, which prompts for when-in-use permission itself when
/// the status is undetermined and reports a denial without prompting again. A `CLBackgroundActivitySession` is
/// held while the stream is read, so a pocketed phone keeps receiving updates (the blue indicator shows for the
/// run); dropping the stream ends both. The activity session is opened on the first authorised update, not before
/// the prompt: one created without effective authorization never becomes active, and Start keeps the app in the
/// foreground until that first element, which is when a new session may become active.
///
/// The first element is guaranteed: a fix, `.denied`, or `.unavailable` after `fixTimeout` of waiting (the clock
/// pauses while the permission prompt is up). A denial ends the stream. A later Core Location failure ends it
/// silently; the session keeps the last fix it had.
final class CoreLocationProvider: LocationProvider {
    /// How long to wait for the first fix once permission is settled. Listening does not start until the first
    /// element arrives, so this caps how long Start can take when no fix is coming.
    nonisolated static let fixTimeout: Duration = .seconds(10)
    private nonisolated static let timeoutTick: Duration = .seconds(1)

    /// Shared between the update task and the timeout task: whether the permission prompt is up, and whether a
    /// first element has gone out.
    private nonisolated final class Progress: Sendable {
        private let state = Mutex((prompting: false, settled: false))

        var isPrompting: Bool {
            get { state.withLock { $0.prompting } }
            set { state.withLock { $0.prompting = newValue } }
        }

        var isSettled: Bool { state.withLock { $0.settled } }

        /// Marks the first element as sent; true the first time only.
        func settle() -> Bool {
            state.withLock { state in
                defer { state.settled = true }
                return !state.settled
            }
        }
    }

    func fixes() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            let task = Task.detached { await Self.deliver(to: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func deliver(to continuation: AsyncStream<LocationFix>.Continuation) async {
        let progress = Progress()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Counted in ticks so the clock pauses while the permission prompt is up.
                var remaining = fixTimeout
                while remaining > .zero, !Task.isCancelled, !progress.isSettled {
                    try? await Task.sleep(for: timeoutTick)
                    if !progress.isPrompting { remaining -= timeoutTick }
                }
                if !Task.isCancelled, progress.settle() { continuation.yield(.unavailable) }
            }
            group.addTask {
                await forward(updates: CLLocationUpdate.liveUpdates(.default), to: continuation, progress: progress)
                continuation.finish()
            }
            await group.waitForAll()
        }
    }

    private nonisolated static func forward(updates: CLLocationUpdate.Updates, to continuation: AsyncStream<LocationFix>.Continuation, progress: Progress) async {
        var activity: CLBackgroundActivitySession?
        defer { activity?.invalidate() }
        do {
            for try await update in updates {
                progress.isPrompting = update.authorizationRequestInProgress
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    _ = progress.settle()
                    continuation.yield(.denied)
                    return
                }
                if activity == nil, !update.authorizationRequestInProgress {
                    activity = CLBackgroundActivitySession()
                }
                if let location = update.location {
                    _ = progress.settle()
                    continuation.yield(.fix(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        accuracy: location.horizontalAccuracy,
                        at: location.timestamp
                    ))
                }
                // Otherwise the request is in progress or no fix is available yet: keep waiting.
            }
        } catch {
            // Cancelled with the stream, or Core Location failed: nothing more is coming.
        }
        if progress.settle() { continuation.yield(.unavailable) }
    }
}
