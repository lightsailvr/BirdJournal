import Album
import Foundation
import Identification
import LensSession
import MWDATCore
import MWDATInputs
import MWDATMockDevice
import SwiftData
import Testing
@testable import BirdJournal

// Pause, disconnect and error handling on Mock Device Kit (issue #10). The mock does not pause a session on a doff
// (DAT-SETUP-CHECKLIST.md), and neither do real glasses: they end it and drop the link (DECISIONS.md, phase A). So
// the mock's power switch stands in for the glasses ending the session (it drops the link, then ends the session
// with "Session ended by device", as the hardware does), with `doff()` first when the wearer took them off, and
// `powerOn()` and `don()` for their return. The mock's touchpad tap pauses the session as the toolkit describes.
// The real doff, out-of-range walk and touchpad are verified on hardware (DAT-SETUP-CHECKLIST.md).
extension MockDeviceKitTests {
    @Suite("Glasses listening interruptions")
    struct GlassesInterruptions {
        /// A run on a stand-in source with fast reconnect timings on the connected mock, started and checked.
        private static func startRun(
            source: ManualAudioSource,
            location: LocationFix = ListeningSessionTests.newYork
        ) async throws -> GlassesListeningSession {
            let connection = GlassesConnection()
            try await waitUntil { connection.connectedDevice != nil }
            var policy = GlassesListeningSession.ReconnectPolicy()
            policy.quitGrace = .milliseconds(500)
            policy.retryDelay = .milliseconds(200)
            let run = GlassesListeningSession(
                recorder: SightingRecorder(container: try AlbumSchema.makeContainer(inMemory: true), frames: FrameStore(directory: temporaryFrames())),
                loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                makeSource: { _ in source },
                location: ScriptedLocationProvider([location]),
                reconnect: policy,
                profile: FakeLensStack.profile(for:),
                image: FakeLensStack.image(for:)
            )
            await run.start()
            try #require(run.phase == .listening, "\(run.errorMessage ?? "no error")")
            try await waitUntil { run.lens.inputsState == .active }
            return run
        }

        /// Whether the mock glasses report themselves off the wearer's face yet.
        private static func isDoffed(_ glasses: any MockGlasses) -> Bool {
            Wearables.shared.deviceForIdentifier(glasses.deviceIdentifier)?.donState == .doffed
        }

        @Test("doff then don: the engine and the pages survive, and audio and cards carry on without a restart")
        func doffThenDon() async throws {
            try await withMockDisplay { glasses in
                let source = ManualAudioSource()
                let run = try await Self.startRun(source: source)
                defer { Task { await run.stop() } }

                source.feed(seconds: 4.5)
                try await waitUntil { run.lens.stack.count == 2 }
                let input = glasses.services.input
                input.navLeft()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .species(index: 0) }
                let windowsBefore = run.listening.windowsScored

                // Off the face: the glasses end the session a few seconds later and the link drops.
                glasses.doff()
                try await waitUntil { Self.isDoffed(glasses) }
                glasses.powerOff()
                try await waitUntil { run.phase == .paused(.glassesOff) }
                #expect(run.lens.phase == .suspended)
                #expect(run.lens.page == .species(index: 0), "the pages wait where the wearer left them")
                #expect(run.listening.phase == .listening, "the engine keeps its stack")
                #expect(source.suspensions == 1)
                #expect(!source.isStopped)
                #expect(run.sessionState == .stopped)
                #expect(run.errorMessage == nil)

                // Back on: a new session under the same pages and the same stream.
                glasses.powerOn()
                glasses.don()
                try await waitUntil(timeout: .seconds(30)) { run.phase == .listening }
                #expect(source.resumedOn.count == 1, "the same stream continues on the new session")
                #expect(run.lens.phase == .running)
                #expect(run.lens.page == .species(index: 0), "a doff is not a problem the wearer needs telling about")
                #expect(run.lens.stack.count == 2)
                try await waitUntil { run.lens.inputsState == .active }

                source.feed(seconds: 3)
                try await waitUntil { run.listening.windowsScored > windowsBefore }
                input.navLeft()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .species(index: 1) }

                await run.stop()
                #expect(run.phase == .stopped(.phone))
                #expect(run.lens.phase == .stopped(.phone))
                #expect(run.listening.phase == .idle)
                #expect(source.isStopped)
            }
        }

        @Test("out of range: the phone shows the pause, the return reconnects, and the lens shows the problem with a way back")
        func outOfRangeAndBack() async throws {
            try await withMockDisplay { glasses in
                let source = ManualAudioSource()
                let run = try await Self.startRun(source: source)
                defer { Task { await run.stop() } }

                source.feed(seconds: 4.5)
                try await waitUntil { run.lens.stack.count == 2 }

                // The link drops while the glasses are worn.
                glasses.powerOff()
                try await waitUntil { run.phase == .paused(.disconnected) }
                #expect(run.lens.phase == .suspended)
                #expect(run.listening.phase == .listening)

                glasses.powerOn()
                try await waitUntil(timeout: .seconds(30)) { run.phase == .listening }
                #expect(run.lens.page == .problem(.connectionLost))
                #expect(run.lens.card.elements[0] == .heading("Connection lost"))
                try await waitUntil { run.lens.inputsState == .active }
                glasses.services.input.navRight()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .list }
                #expect(run.lens.card.elements[0] == .heading("2 species heard"))

                await run.stop()
                #expect(run.phase == .stopped(.phone))
            }
        }

        @Test("the touchpad pauses the session: the phone says so, and the run carries on when it resumes")
        func touchpadPause() async throws {
            try await withMockDisplay { glasses in
                let source = ManualAudioSource()
                let run = try await Self.startRun(source: source)
                defer { Task { await run.stop() } }

                source.feed(seconds: 4.5)
                try await waitUntil { run.lens.stack.count == 2 }
                glasses.services.input.navLeft()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .species(index: 0) }

                glasses.services.captouch.tap()
                try await waitUntil { run.phase == .paused(.byGlasses) }
                #expect(run.sessionState == .paused)
                #expect(run.lens.phase == .running, "the toolkit keeps the capabilities through its own pause")
                #expect(run.listening.phase == .listening)
                #expect(source.suspensions == 0)

                glasses.services.captouch.tap()
                try await waitUntil { run.phase == .listening }
                #expect(run.sessionState == .started)
                #expect(source.resumedOn.isEmpty, "the same session resumed")
                #expect(run.lens.page == .species(index: 0))

                await run.stop()
                #expect(run.phase == .stopped(.phone))
            }
        }

        @Test("stop while waiting for the glasses ends everything")
        func stopWhilePaused() async throws {
            try await withMockDisplay { glasses in
                let source = ManualAudioSource()
                let run = try await Self.startRun(source: source)

                glasses.doff()
                try await waitUntil { Self.isDoffed(glasses) }
                glasses.powerOff()
                try await waitUntil { run.phase == .paused(.glassesOff) }

                await run.stop()
                #expect(run.phase == .stopped(.phone))
                #expect(run.lens.phase == .stopped(.phone))
                #expect(run.listening.phase == .idle)
                #expect(source.isStopped)

                // The glasses coming back now start nothing.
                glasses.powerOn()
                glasses.don()
                try await Task.sleep(for: .seconds(2))
                #expect(run.phase == .stopped(.phone))
                #expect(run.lens.phase == .stopped(.phone))
                #expect(source.resumedOn.isEmpty)
            }
        }

        @Test("no location: the lens shows the problem over the list, and swipe right is the way back")
        func noLocation() async throws {
            try await withMockDisplay { glasses in
                let source = ManualAudioSource()
                let run = try await Self.startRun(source: source, location: .denied)
                defer { Task { await run.stop() } }

                #expect(run.lens.page == .problem(.noLocation))
                #expect(run.lens.card.elements[0] == .heading("No location"))
                #expect(run.listening.locationState == .settled(.denied))

                // Species heard meanwhile append behind the problem page.
                source.feed(seconds: 4.5)
                try await waitUntil { run.lens.stack.count == 2 }
                #expect(run.lens.page == .problem(.noLocation))

                glasses.services.input.navRight()
                try await waitUntil(timeout: .seconds(1)) { run.lens.page == .list }
                #expect(run.lens.card.elements[0] == .heading("2 species heard"))

                await run.stop()
                #expect(run.phase == .stopped(.phone))
            }
        }

        @Test("three start-stop cycles leave nothing behind: each cycle works alone, and the run is released after")
        func threeCycles() async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                weak var released: GlassesListeningSession?
                var sources: [ManualAudioSource] = []
                do {
                    let album = try AlbumSchema.makeContainer(inMemory: true)
                    let run = GlassesListeningSession(
                        recorder: SightingRecorder(container: album, frames: FrameStore(directory: Self.temporaryFrames())),
                        loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                        makeSource: { _ in
                            let source = ManualAudioSource()
                            sources.append(source)
                            return source
                        },
                        location: ScriptedLocationProvider([ListeningSessionTests.newYork]),
                        profile: FakeLensStack.profile(for:),
                        image: FakeLensStack.image(for:)
                    )
                    released = run
                    let input = glasses.services.input
                    for cycle in 1...3 {
                        await run.start()
                        try #require(run.phase == .listening, "cycle \(cycle): \(run.errorMessage ?? "no error")")
                        #expect(run.lens.page == .list)
                        #expect(run.lens.stack.isEmpty, "cycle \(cycle) starts with a fresh stack")
                        #expect(run.lens.inputRecords.isEmpty)
                        try await waitUntil { run.lens.inputsState == .active }
                        sources[cycle - 1].feed(seconds: 4.5)
                        try await waitUntil { run.lens.stack.count == 2 }
                        input.navLeft()
                        try await waitUntil(timeout: .seconds(1)) { run.lens.page == .species(index: 0) }
                        #expect(run.lens.inputRecords.count == 1, "cycle \(cycle): one gesture delivered once")

                        await run.stop()
                        #expect(run.phase == .stopped(.phone))
                        #expect(run.lens.phase == .stopped(.phone))
                        #expect(run.listening.phase == .idle)
                        #expect(run.sessionState == .stopped)
                        #expect(sources[cycle - 1].isStopped)
                        #expect(run.lens.inputsState == .inactive)
                        // Nothing listens any more: a gesture now goes nowhere.
                        input.select()
                        try await Task.sleep(for: .milliseconds(300))
                        #expect(run.lens.inputRecords.count == 1)
                    }
                    #expect(sources.count == 3)
                    #expect(try album.mainContext.fetchCount(FetchDescriptor<Sighting>()) == 0)
                }
                // Every task the run spawned has finished or holds it weakly, so nothing keeps it alive.
                for _ in 0..<20 where released != nil { await Task.yield() }
                #expect(released == nil, "the run is retained after three cycles")
            }
        }

        private static func temporaryFrames() -> URL {
            URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
    }
}

/// The classifiers behind the run's decisions, on device states the toolkit could report (no mock needed).
@Suite("Glasses interruption rules")
struct GlassesInterruptionRules {
    typealias PauseReason = GlassesListeningSession.PauseReason

    @Test("why the glasses ended a session: doffed first, then a link that is not up, else the wearer quit")
    func whyEnded() {
        #expect(PauseReason.whyEnded(DeviceState(linkState: .connected, donState: .doffed)) == .glassesOff)
        #expect(PauseReason.whyEnded(DeviceState(linkState: .disconnected, donState: .doffed)) == .glassesOff)
        #expect(PauseReason.whyEnded(DeviceState(linkState: .disconnected, donState: .donned)) == .disconnected)
        #expect(PauseReason.whyEnded(DeviceState(linkState: .connecting, donState: .unknown)) == .disconnected)
        #expect(PauseReason.whyEnded(DeviceState(linkState: .connected, donState: .donned)) == nil)
        #expect(PauseReason.whyEnded(DeviceState(linkState: .connected, donState: .unknown)) == nil)
    }

    @Test("glasses are worn and connected when the link is up and they are not known to be off")
    func wornAndConnected() {
        #expect(DeviceState(linkState: .connected, donState: .donned).isWornAndConnected)
        #expect(DeviceState(linkState: .connected, donState: .unknown).isWornAndConnected)
        #expect(!DeviceState(linkState: .connected, donState: .doffed).isWornAndConnected)
        #expect(!DeviceState(linkState: .connecting, donState: .donned).isWornAndConnected)
    }

    @Test("errors the glasses cannot recover from end the run; their own end and the unknown do not")
    func endsRun() {
        #expect(DeviceSessionError.batteryCritical.endsRun)
        #expect(DeviceSessionError.thermalEmergency.endsRun)
        #expect(DeviceSessionError.datAppOnTheGlassesUpdateRequired.endsRun)
        #expect(!DeviceSessionError.unexpectedError(description: "Session ended by device").endsRun)
        #expect(!DeviceSessionError.dwaOutOfStuRange.endsRun)
    }
}
