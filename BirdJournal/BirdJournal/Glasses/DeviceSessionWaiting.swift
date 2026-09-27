import MWDATCore
import Synchronization

// Waiting helpers shared by the glasses adapters (`GlassesAudioSource`, `GlassesLensSession`). The toolkit
// resolves devices and starts sessions asynchronously and reports progress through publishers, so every
// adapter needs "wait for this state, or give up after a while".

extension AutoDeviceSelector {
    /// Waits up to `timeout` for the selector to pick a connected device; false if none appears.
    func waitForDevice(timeout: Duration = .seconds(10)) async -> Bool {
        if activeDevice != nil { return true }
        return await completes(within: timeout) {
            for await device in self.activeDeviceStream() where device != nil { return true }
            return false
        }
    }
}

extension DeviceSession {
    /// Waits for `.started`; false if the session stops first or `timeout` passes.
    func waitUntilStarted(timeout: Duration = .seconds(30)) async -> Bool {
        await completes(within: timeout) {
            if self.state == .started { return true }
            for await state in self.stateStream() {
                if state == .started { return true }
                if state == .stopped { return false }
            }
            return false
        }
    }
}

extension Announcer {
    /// Waits until a published value decides the outcome (`true` or `false`); `nil` keeps waiting. False once
    /// `timeout` passes. Subscribe before triggering the transition: values published earlier are not replayed.
    func waitUntil(timeout: Duration, _ outcome: @escaping @Sendable (T) -> Bool?) async -> Bool {
        let (values, continuation) = AsyncStream.makeStream(of: T.self, bufferingPolicy: .unbounded)
        let bag = ListenerTokenBag()
        listen { continuation.yield($0) }.store(in: bag)
        defer {
            bag.clear()
            continuation.finish()
        }
        return await completes(within: timeout) {
            for await value in values {
                if let decided = outcome(value) { return decided }
            }
            return false
        }
    }
}

/// Runs `operation` and returns its result, or false once `timeout` passes. Returns at the timeout even if
/// `operation` ignores cancellation, which a task group would wait for.
func completes(within timeout: Duration, _ operation: @escaping @Sendable () async -> Bool) async -> Bool {
    let resumed = ResumeOnce()
    return await withCheckedContinuation { continuation in
        let work = Task {
            let result = await operation()
            if resumed.claim() { continuation.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
            if resumed.claim() { continuation.resume(returning: false) }
        }
    }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class ResumeOnce: Sendable {
    private let resumed = Mutex(false)

    func claim() -> Bool {
        resumed.withLock { resumed in
            defer { resumed = true }
            return !resumed
        }
    }
}
