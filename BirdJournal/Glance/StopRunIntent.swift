import AppIntents

/// Stop on the Live Activity (issue #150). A live activity intent runs in the app's process, so this is built into both
/// targets and only the app ever performs it. Launched by it with no run on (the app was killed mid-run), the app has already
/// ended the leftover activity, and there is nothing to stop.
struct StopRunIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Stop listening"
    nonisolated static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await RunStopper.stop?()
        return .result()
    }
}

/// Where the intent reaches the run. The app sets it at launch to the coordinator's stop.
enum RunStopper {
    static var stop: (@MainActor () async -> Void)?
}
