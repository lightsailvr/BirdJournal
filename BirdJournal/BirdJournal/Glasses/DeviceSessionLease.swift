import Foundation
import MWDATCore
import Synchronization

/// How a glasses adapter comes by its device session. The toolkit allows one session per device
/// (`DeviceSessionError.sessionAlreadyExists`), so the listening run (issue #9) starts one and shares it between
/// the camera stream, Display and Inputs; the single-capability screens and the mock tests still let each adapter
/// start its own.
enum DeviceSessionLease {
    /// Start a session on the connected display glasses and stop it on teardown.
    case own
    /// Attach to a session someone else started and keeps running; teardown leaves it to them.
    case shared(DeviceSession)

    var isOwned: Bool {
        if case .own = self { return true }
        return false
    }

    /// The started session this lease gives. `listen` adds the adapter's state and error listeners: before `start()`
    /// on an own session so nothing is missed, right away on a shared one.
    func session(wearables: any WearablesInterface, listen: (DeviceSession) -> Void) async throws -> DeviceSession {
        switch self {
        case .own:
            return try await Self.startSession(wearables: wearables, listen: listen)
        case .shared(let session):
            guard session.state == .started else { throw DeviceSessionStartError.sharedSessionNotRunning }
            listen(session)
            return session
        }
    }

    /// Creates and starts a session on the first connected display glasses and waits for `.started`. A session
    /// that stops first reports the error the toolkit published on the way, if any.
    static func startSession(wearables: any WearablesInterface, listen: (DeviceSession) -> Void = { _ in }) async throws -> DeviceSession {
        let selector = AutoDeviceSelector(wearables: wearables) { $0.supportsDisplay() }
        guard await selector.waitForDevice() else { throw DeviceSessionStartError.noDisplayGlasses }
        let session = try wearables.createSession(deviceSelector: selector)
        let lastError = Mutex<DeviceSessionError?>(nil)
        let tokens = ListenerTokenBag()
        session.errorPublisher.listen { error in lastError.withLock { $0 = error } }.store(in: tokens)
        defer { tokens.clear() }
        listen(session)
        do {
            try session.start()
        } catch {
            session.stop()
            throw error
        }
        guard await session.waitUntilStarted() else {
            session.stop()
            throw DeviceSessionStartError.sessionDidNotStart(lastError.withLock { $0 })
        }
        return session
    }
}

enum DeviceSessionStartError: LocalizedError {
    case noDisplayGlasses
    /// Carries the session error reported before the session stopped, if any.
    case sessionDidNotStart(DeviceSessionError?)
    case sharedSessionNotRunning

    var errorDescription: String? {
        switch self {
        case .noDisplayGlasses: "No connected display glasses."
        case .sessionDidNotStart(let error?): "The glasses session did not start: \(error.description)"
        case .sessionDidNotStart(nil): "The glasses session did not start."
        case .sharedSessionNotRunning: "The glasses session is not running."
        }
    }
}
