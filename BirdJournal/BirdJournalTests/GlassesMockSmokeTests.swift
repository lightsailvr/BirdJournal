import MWDATCamera
import MWDATCore
import MWDATMockDevice
import Testing
import UIKit
@testable import BirdJournal

// Glasses adapter smoke tests against Mock Device Kit (spec "Testing"). They run app-hosted because
// `Wearables.configure()` needs the host app's bundle; the app calls it at launch. No audio assertions: the mock
// cannot inject audio frames, and it does not model doff pausing a session, so pause and resume are verified on
// hardware with the spike log.
@Suite("Glasses adapter on Mock Device Kit", .serialized)
struct GlassesMockSmokeTests {
    @Test("a paired mock Display shows as registered, connected and compatible")
    func registrationAndDeviceStatus() async throws {
        try await withMockDisplay { glasses in
            let connection = GlassesConnection()

            try await waitUntil { connection.registrationState == .registered }
            try await waitUntil {
                connection.devices.contains {
                    $0.id == glasses.deviceIdentifier && $0.state.linkState == .connected && $0.state.compatibility == .compatible
                }
            }
        }
    }

    @Test("the glasses audio source starts a session and an audio-enabled camera stream")
    func audioSourceSessionPath() async throws {
        try await withStartedSource { source, _, log in
            #expect(source.sessionState == .started)
            // The mock stream reaches `.streaming`, then times out for lack of audio frames; only the transition counts.
            try await waitUntil { log.streamStates.contains(.streaming) }
        }
    }

    // MARK: - Helpers

    /// Pairs a mock Display (registered, permissions granted, powered on, unfolded, worn) and always disables
    /// Mock Device Kit afterwards, so a failing test does not leave the next one with a stale device.
    private func withMockDisplay(_ body: (any MockGlasses) async throws -> Void) async throws {
        MockDeviceKit.shared.enable()
        do {
            let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            try await body(glasses)
        } catch {
            await MockDeviceKit.shared.disable()
            throw error
        }
        await MockDeviceKit.shared.disable()
    }

    /// Starts a `GlassesAudioSource` on a connected mock Display, records its events, and always stops it.
    private func withStartedSource(
        _ body: (GlassesAudioSource, any MockGlasses, EventLog) async throws -> Void
    ) async throws {
        try await withMockDisplay { glasses in
            glasses.services.camera.setCameraFeed(fileURL: try makeFeedImage())
            let connection = GlassesConnection()
            try await waitUntil { connection.connectedDevice != nil }

            let source = GlassesAudioSource()
            let log = EventLog()
            let watcher = Task { for await event in source.events { log.events.append(event) } }
            defer { watcher.cancel() }

            do {
                _ = try await source.start()
                try await body(source, glasses, log)
            } catch {
                await source.stop()
                throw error
            }
            await source.stop()
        }
    }

    /// The mock camera needs a feed or the stream fails with `videoStreamingError`.
    private func makeFeedImage() throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        }
        let url = URL.temporaryDirectory.appending(path: "mock-feed.png")
        try #require(image.pngData()).write(to: url)
        return url
    }

    private func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Condition not met within \(timeout)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Events a `GlassesAudioSource` published during a test.
private final class EventLog {
    var events: [GlassesAudioSource.Event] = []

    var streamStates: [StreamState] {
        events.compactMap { if case .streamState(let state) = $0 { state } else { nil } }
    }
}
