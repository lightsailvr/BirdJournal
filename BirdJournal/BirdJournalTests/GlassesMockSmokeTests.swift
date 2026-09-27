import MWDATCamera
import MWDATCore
import MWDATMockDevice
import Testing
@testable import BirdJournal

// Glasses adapter smoke tests against Mock Device Kit (spec "Testing"). No audio assertions: the mock cannot
// inject audio frames. The run's pause and resume paths are in `GlassesInterruptionTests` (issue #10).
extension MockDeviceKitTests {
    @Suite("Glasses adapter")
    struct GlassesAdapter {
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

        @Test("the audio source outlives its session: suspended when it ends, resumed on the next, one chunk stream throughout (issue #10)")
        func audioSourceSurvivesSessionChange() async throws {
            try await withMockDisplay { glasses in
                glasses.services.camera.setCameraFeed(fileURL: try makeFeedImage())
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }

                let first = try await DeviceSessionLease.startSession(wearables: connection.wearables)
                let source = GlassesAudioSource(lease: .shared(first))
                let log = EventLog()
                let watcher = Task { for await event in source.events { log.events.append(event) } }
                defer { watcher.cancel() }
                let chunks = try await source.start()
                let chunksEnded = Flag()
                let reader = Task { for await _ in chunks {}; chunksEnded.value = true }
                defer { reader.cancel() }
                try await waitUntil { log.streamStates.contains(.streaming) }

                // The session ends under the stream: the camera goes, the chunk stream does not.
                await source.suspend()
                #expect(source.streamState == .stopped)
                first.stop()
                try await Task.sleep(for: .milliseconds(300))
                #expect(!chunksEnded.value, "the engine must see a silence, not an end")

                let second = try await DeviceSessionLease.startSession(wearables: connection.wearables)
                try await source.resume(on: second)
                try await waitUntil { log.streamStates.filter { $0 == .streaming }.count == 2 }

                await source.stop()
                try await waitUntil { chunksEnded.value }
                second.stop()
            }
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
    }
}

private final class Flag {
    var value = false
}

/// Events a `GlassesAudioSource` published during a test.
private final class EventLog {
    var events: [GlassesAudioSource.Event] = []

    var streamStates: [StreamState] {
        events.compactMap { if case .streamState(let state) = $0 { state } else { nil } }
    }
}
