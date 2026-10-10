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
                // The state reaches the source on a hop to the main actor, so it may still read `.starting` here.
                try await waitUntil { source.sessionState == .started }
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

        @Test("a clip takes the camera off and the stream comes back on the same session once it ends, a song then a call holding it once")
        func audioSourceRestartsAfterAClip() async throws {
            try await withStartedSource { source, _, log in
                try await waitUntil { log.streamStates.contains(.streaming) }
                let streamed = { log.streamStates.filter { $0 == .streaming }.count }

                await source.holdForPlayback()
                #expect(source.streamState == .stopped)
                source.releaseAfterPlayback()
                // The call starts inside the restart delay: the stream stays off for it.
                try await Task.sleep(for: .milliseconds(300))
                await source.holdForPlayback()
                try await Task.sleep(for: GlassesAudioSource.restartDelay + .milliseconds(500))
                #expect(streamed() == 1)
                #expect(source.sessionState == .started)

                source.releaseAfterPlayback()
                try await waitUntil(timeout: .seconds(15)) { streamed() == 2 }
                #expect(source.sessionState == .started)
            }
        }

        @Test("a full-resolution photo takes the stream off, comes from the photo capability, and the stream comes back")
        func audioSourceFullPhoto() async throws {
            try await withStartedSource { source, glasses, log in
                try await waitUntil { log.streamStates.contains(.streaming) }
                let photoURL = try makeFeedImage()
                glasses.services.cameraCapture.setCapturedPhoto(fileURL: photoURL)
                let streamed = { log.streamStates.filter { $0 == .streaming }.count }

                let photo = await source.capturePhoto()
                let data = try #require(photo, "the mock's photo")
                #expect(data.starts(with: [0xFF, 0xD8]), "stored as a JPEG")
                try await waitUntil(timeout: .seconds(15)) { streamed() == 2 }
                #expect(source.sessionState == .started)
            }
        }

        @Test("the viewfinder restarts the stream sharper and faster, and closing it goes back to the listening stream")
        func audioSourceViewfinderStream() async throws {
            try await withStartedSource { source, _, log in
                try await waitUntil { log.streamStates.contains(.streaming) }
                let streamed = { log.streamStates.filter { $0 == .streaming }.count }
                #expect(source.configuration.resolution == .low)

                await source.setViewfinder(open: true)
                #expect(source.configuration.resolution == .medium)
                #expect(source.configuration.frameRate == 7)
                try await waitUntil(timeout: .seconds(15)) { streamed() == 2 }

                await source.setViewfinder(open: false)
                #expect(source.configuration.resolution == .low)
                try await waitUntil(timeout: .seconds(15)) { streamed() == 3 }
                #expect(source.sessionState == .started)
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
