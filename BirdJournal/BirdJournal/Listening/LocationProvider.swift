import CoreLocation
import Foundation
import Synchronization

/// What one location request came back with.
nonisolated enum LocationFix: Equatable, Sendable {
    case fix(latitude: Double, longitude: Double, at: Date)
    /// The user declined when-in-use permission, or it is restricted. Identification carries on without the geo
    /// filter (issue #6).
    case denied
    /// Permission is fine but no fix arrived in time.
    case unavailable
}

/// The location seam for a listening session: one fix on request. DECISIONS.md: when-in-use permission, one fix
/// at session start, refreshed every ten minutes, no background location mode.
protocol LocationProvider {
    /// Asks for when-in-use permission the first time (the system prompts once) and returns one fix.
    func currentFix() async -> LocationFix
}

/// Core Location through `CLLocationUpdate.liveUpdates`, which prompts for when-in-use permission itself when
/// the status is undetermined. Stops iterating after the first fix, so the location hardware runs for seconds per
/// request, not for the session.
final class CoreLocationProvider: LocationProvider {
    /// How long to wait for a fix once permission is settled.
    static let fixTimeout: Duration = .seconds(20)

    /// Shared between the fix task and the timeout task: whether the permission prompt is up.
    private nonisolated final class PromptFlag: Sendable {
        private let value = Mutex(false)
        var isPrompting: Bool {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    func currentFix() async -> LocationFix {
        let prompt = PromptFlag()
        return await withTaskGroup(of: LocationFix.self) { group in
            group.addTask { await Self.firstFix(prompt: prompt) }
            group.addTask {
                // The clock does not run while the permission prompt is up.
                repeat {
                    try? await Task.sleep(for: Self.fixTimeout)
                } while prompt.isPrompting && !Task.isCancelled
                return .unavailable
            }
            let first = await group.next() ?? .unavailable
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func firstFix(prompt: PromptFlag) async -> LocationFix {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                prompt.isPrompting = update.authorizationRequestInProgress
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    return .denied
                }
                if let location = update.location {
                    return .fix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, at: location.timestamp)
                }
                // Otherwise the request is in progress or no fix is available yet: keep waiting.
            }
        } catch {
            // Cancelled by the timeout, or Core Location failed: either way there is no fix.
        }
        return .unavailable
    }
}
