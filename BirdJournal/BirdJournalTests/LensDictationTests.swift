import Album
import Foundation
import Identification
import LensSession
import MWDATCore
import MWDATInputs
import MWDATMockDevice
import SwiftData
import Synchronization
import Testing
import UIKit
@testable import BirdJournal

// Saying the bird's name on the lens (issue #194, of #185), on Mock Device Kit: the toolkit's Speech on the run's own
// session, with the transcriptions, completion and error its mock injects. The run is the real one over a stand-in
// stream, as in the capture tests; what cannot be had here is a real voice in real glasses (#195).
extension MockDeviceKitTests {
    @Suite("Saying the bird's name on the lens")
    struct LensDictation {
        /// A field guide with a phoebe, a finch and a jay, and the two birds the scripted model hears beside them.
        nonisolated static let names = NameableBirds(
            fieldGuide: [
                .init(scientificName: "Sayornis nigricans", commonName: "Black Phoebe"),
                .init(scientificName: "Haemorhous mexicanus", commonName: "House Finch"),
                .init(scientificName: "Cyanocitta stelleri", commonName: "Steller's Jay"),
            ],
            labels: [
                Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"),
                Species(index: 1, scientificName: "Cyanocitta cristata", commonName: "Blue Jay", taxonomicClass: "Aves"),
                Species(index: 2, scientificName: "Sayornis nigricans", commonName: "Black Phoebe", taxonomicClass: "Aves"),
                Species(index: 3, scientificName: "Cyanocitta stelleri", commonName: "Steller's Jay", taxonomicClass: "Aves"),
                Species(index: 4, scientificName: "Aphelocoma californica", commonName: "California Scrub-Jay", taxonomicClass: "Aves"),
            ]
        )

        /// A glasses run on the mock whose lens can ask for a bird's name.
        @MainActor
        struct Stage {
            let glasses: any MockGlasses
            let source: ManualAudioSource
            let album: ModelContainer
            let glassesRun: GlassesListeningSession
            let run: ListeningCoordinator
            var lens: GlassesLensSession { glassesRun.lens }
            var speech: any MockSpeechKit { glasses.services.speech }
            var input: any MockInputKit { glasses.services.input }

            /// From the list to the tap that takes the photo: up to the row if a bird has the highlight, a tap, a beat for
            /// the viewfinder's echo window, and a tap. Returns once the photo is written.
            func takePhoto() async throws {
                try #require(lens.page == .list)
                if !lens.machine.isCaptureRowHighlighted {
                    input.navUp()
                    try await waitUntil(timeout: .seconds(2)) { lens.machine.isCaptureRowHighlighted }
                }
                let taken = run.sightings.unnamed.count + run.sightings.seen.count
                input.select()
                try await waitUntil(timeout: .seconds(2)) { lens.page == .captureViewfinder }
                try await Task.sleep(for: .milliseconds(1100))
                input.select()
                try await waitUntil(timeout: .seconds(5)) { run.sightings.unnamed.count + run.sightings.seen.count == taken + 1 }
            }

            /// A photo taken, and the lens on "Say the bird's name" with the glasses listening.
            func askForAName() async throws {
                try await takePhoto()
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureNaming }
                try await waitUntil(timeout: .seconds(5)) { speech.isListening }
            }

            /// The rows of the birds' page.
            var choices: [LensChoiceRow] {
                for element in lens.card.elements {
                    if case .choices(let rows) = element { return rows }
                }
                return []
            }
        }

        /// Starts a run with a camera frame and a photo to take, hands it over, and stops it whatever happens.
        static func withRun(
            limits: GlassesDictation.Limits = GlassesDictation.Limits(),
            keepsStream: Bool = true,
            names: @escaping @Sendable () async -> NameableBirds? = { LensDictation.names },
            _ body: (Stage) async throws -> Void
        ) async throws {
            try await withMockDisplay { glasses in
                let connection = GlassesConnection()
                try await waitUntil { connection.connectedDevice != nil }
                let source = ManualAudioSource()
                source.latestFrame = frame(.red)
                source.photo = frame(.green).jpegData()
                let album = try AlbumSchema.makeContainer(inMemory: true)
                let recorder = SightingRecorder(container: album, frames: FrameStore(directory: URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)))
                let sightings = RunSightings(recorder: recorder)
                let glassesRun = GlassesListeningSession(
                    recorder: recorder,
                    sightings: sightings,
                    loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
                    makeSource: { _ in source },
                    location: ScriptedLocationProvider([ListeningSessionTests.newYork]),
                    profile: FakeLensStack.profile(for:),
                    image: FakeLensStack.image(for:),
                    names: names,
                    occurrenceModel: SpyOccurrence(),
                    dictationLimits: limits,
                    dictationKeepsStream: { keepsStream }
                )
                let defaults = try #require(UserDefaults(suiteName: "lens-dictation-\(UUID().uuidString)"))
                let run = ListeningCoordinator(phone: ListeningSession(), glasses: glassesRun, sightings: sightings, levels: LevelSink(), defaultSource: .glasses, defaults: defaults)
                await run.start()
                do {
                    try #require(run.state == .listening, "\(run.errorMessage ?? "no error")")
                    try await waitUntil { glassesRun.lens.inputsState == .active }
                    try await body(Stage(glasses: glasses, source: source, album: album, glassesRun: glassesRun, run: run))
                } catch {
                    await run.stop()
                    throw error
                }
                await run.stop()
            }
        }

        /// A solid 64×64 frame, encoded like the stream's frames are.
        private static func frame(_ color: UIColor) -> CameraFrame {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            let data = image.jpegData(compressionQuality: 0.9)
            return CameraFrame { data }
        }

        // Review of #185, B3 (spec c4): the names were read once per launch.
        @Test("each run reads the names again, so a field guide downloaded between two runs is known to the second")
        func namesAreReadForEachRun() async throws {
            let reads = ReadCount()
            try await Self.withRun(names: {
                reads.add()
                return Self.names
            }) { stage in
                let (lens, run, speech) = (stage.lens, stage.run, stage.speech)
                try await stage.askForAName()
                speech.simulateTranscription(text: "Jay.", isFinal: true, confidence: -1)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(reads.count == 1)

                // A second photo of the same run reads nothing again.
                for _ in 0..<4 { stage.input.navDown() }
                try await waitUntil(timeout: .seconds(2)) { stage.choices.last?.isSelected == true }
                stage.input.select()
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureSaved }
                stage.input.select()
                try await waitUntil(timeout: .seconds(2)) { lens.page == .list }
                try await stage.askForAName()
                speech.simulateTranscription(text: "Jay.", isFinal: true, confidence: -1)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(reads.count == 1, "once a run")

                // The next run.
                await run.stop()
                await run.start()
                try #require(run.state == .listening, "\(run.errorMessage ?? "no error")")
                try await waitUntil { lens.inputsState == .active }
                try await stage.askForAName()
                speech.simulateTranscription(text: "Jay.", isFinal: true, confidence: -1)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(reads.count == 2, "read again for the new run")
            }
        }

        // Review of #185, B4.
        @Test("a photo still on its way when its run stops, and arriving once the next run is listening, is kept to name and is not the new run's: not under Seen this run, and the new run's lens is not asked for its name")
        func aLatePhotoIsNotTheNextRuns() async throws {
            try await Self.withRun { stage in
                let (lens, run, input) = (stage.lens, stage.run, stage.input)
                stage.source.holdsPhoto = true
                do {
                    input.navUp()
                    try await waitUntil(timeout: .seconds(2)) { lens.machine.isCaptureRowHighlighted }
                    input.select()
                    try await waitUntil(timeout: .seconds(2)) { lens.page == .captureViewfinder }
                    try await Task.sleep(for: .milliseconds(1100))
                    input.select()
                    try await waitUntil(timeout: .seconds(2)) { lens.page == .captureSaving }
                    await run.stop()
                    await run.start()
                    try #require(run.state == .listening, "\(run.errorMessage ?? "no error")")
                    try await waitUntil { lens.inputsState == .active }
                    #expect(lens.page == .list)
                } catch {
                    stage.source.deliverPhoto()
                    throw error
                }

                stage.source.deliverPhoto()
                try await waitUntil(timeout: .seconds(5)) { (try? stage.album.mainContext.fetchCount(FetchDescriptor<Capture>())) == 1 }
                // Long enough for the lens to have been told, had it been.
                try await Task.sleep(for: .milliseconds(500))
                #expect(run.sightings.unnamed.isEmpty, "the new run did not take it")
                #expect(lens.page == .list, "and its lens says nothing of it")
                #expect(!stage.speech.isListening)
                #expect(try stage.album.mainContext.fetch(FetchDescriptor<Capture>()).first?.source == .glasses, "kept, to name from the Collection")
            }
        }

        @Test("after the photo the lens asks for the bird's name and the glasses listen; the words show as they are heard; the final ones bring the birds they may be, heard this run first; a tap names the photo, Seen, and the lens says what it earned; the stitch-in waits for the run's end")
        func namesThePhotoByVoice() async throws {
            try await Self.withRun { stage in
                let (lens, run, speech, input) = (stage.lens, stage.run, stage.speech, stage.input)
                // The finch and the Blue Jay are heard: the run's birds.
                stage.source.feed(seconds: 4.5)
                try await waitUntil { lens.stack.count == 2 }
                #expect(!speech.isListening, "Speech is not on the session while the lens shows the list")

                try await stage.askForAName()
                #expect(lens.card.elements == [.heading("Say the bird's name"), .capturedPhoto, .meta("Listening…"), .meta("Tap: name it later on the phone")])
                #expect(run.sightings.unnamed.count == 1, "the photo is on the phone before any name")
                #expect(stage.source.dictationHolds == 0, "the stream stays on: the switch is on")

                // Words as they arrive.
                speech.simulateTranscription(text: "blue", isFinal: false, confidence: 0.4)
                try await waitUntil(timeout: .seconds(2)) { lens.card.elements.contains(.body("blue")) }
                #expect(lens.page == .captureNaming)

                // The final words: "jay" is three birds here. The one heard this run is first, though no field guide has it;
                // then the field guide's; then the other.
                speech.simulateTranscription(text: "Jay.", isFinal: true, confidence: -1)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(lens.card.elements.first == .status("You said: Jay."))
                #expect(stage.choices == [
                    LensChoiceRow(label: "Blue Jay", detail: "New patch", isSelected: true),
                    LensChoiceRow(label: "Steller's Jay", detail: "New patch", isSelected: false),
                    LensChoiceRow(label: "California Scrub-Jay", detail: "New patch", isSelected: false),
                    LensChoiceRow(label: "Say it again", detail: nil, isSelected: false),
                    LensChoiceRow(label: "Name it later", detail: nil, isSelected: false),
                ])
                // Speech ran for that page only: it is stopped and off the session.
                try await waitUntil(timeout: .seconds(5)) { !speech.isListening }

                // Swipes move the highlight; a tap chooses.
                input.navDown()
                try await waitUntil(timeout: .seconds(2)) { stage.choices.map(\.isSelected) == [false, true, false, false, false] }
                input.navUp()
                try await waitUntil(timeout: .seconds(2)) { stage.choices.first?.isSelected == true }
                #expect(try stage.album.mainContext.fetchCount(FetchDescriptor<Sighting>()) == 0, "nothing is added until a bird is chosen")
                input.select()
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureAdded }
                #expect(lens.card.elements == [
                    .title("Blue Jay", detail: "Seen"),
                    .meta("Uncharted"),
                    .saved("Added"),
                    .body("New patch, sewn on your phone."),
                    .meta("Tap or swipe right: all species"),
                ])

                // On the phone: the unnamed sighting is the Blue Jay's sighting, Seen, named by the birder, from the glasses,
                // with the photo; the run lists it under "Seen this run".
                let sightings = try stage.album.mainContext.fetch(FetchDescriptor<Sighting>())
                let sighting = try #require(sightings.first)
                #expect(sightings.count == 1)
                #expect(sighting.scientificName == "Cyanocitta cristata")
                #expect(sighting.method == .seen)
                #expect(sighting.namedByBirder)
                #expect(sighting.source == .glasses)
                #expect(sighting.attachedPhotoPaths.count == 1)
                #expect(try stage.album.mainContext.fetchCount(FetchDescriptor<Capture>()) == 0)
                #expect(run.sightings.unnamed.isEmpty)
                #expect(run.sightings.seen.map(\.scientificName) == ["Cyanocitta cristata"])
                // As for an add on the lens, the ceremony is for the phone once the run is over.
                #expect(run.reveal == nil)
                #expect(!run.hasCeremonyWaiting)

                input.select()
                try await waitUntil(timeout: .seconds(2)) { lens.page == .list }
                #expect(lens.machine.isCaptureRowHighlighted)

                // The next photo of the same bird: the patch is sewn, so the row says nothing of a new one, and the lens
                // says it was seen again.
                try await stage.askForAName()
                speech.simulateTranscription(text: "blue jay", isFinal: true, confidence: 0.9)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(stage.choices.first == LensChoiceRow(label: "Blue Jay", detail: nil, isSelected: true))
                input.select()
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureAdded }
                #expect(lens.card.elements.contains(.body("Seen again · 2 times")))

                await run.stop()
                #expect(run.hasCeremonyWaiting, "the Blue Jay's stitch-in, now that the run is over")
                #expect(run.waitingCeremonies == 1, "one patch was sewn, not two")
                #expect(run.errorMessage == nil)
            }
        }

        @Test("words no bird answers to say so; \"Say it again\" listens again on the same session; \"Name it later\" leaves the photo unnamed on the phone")
        func noMatchAgainAndLater() async throws {
            try await Self.withRun { stage in
                let (lens, run, speech, input) = (stage.lens, stage.run, stage.speech, stage.input)
                try await stage.askForAName()
                speech.simulateTranscription(text: "flibber jibbet", isFinal: true, confidence: 0.2)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(lens.card.elements == [
                    .status("You said: flibber jibbet"),
                    .heading("No bird by that name"),
                    .choices([
                        LensChoiceRow(label: "Say it again", detail: nil, isSelected: true),
                        LensChoiceRow(label: "Name it later", detail: nil, isSelected: false),
                    ]),
                    .meta("Swipe down: next · tap: choose"),
                ])
                try await waitUntil(timeout: .seconds(5)) { !speech.isListening }

                // Again: Speech goes back on the session, with nothing heard yet.
                input.select()
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureNaming }
                try await waitUntil(timeout: .seconds(5)) { speech.isListening }
                #expect(lens.card.elements.contains(.meta("Listening…")))
                speech.simulateTranscription(text: "black feeby", isFinal: true, confidence: 0.6)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(stage.choices.map(\.label) == ["Black Phoebe", "Say it again", "Name it later"])

                // Down to "Name it later".
                input.navDown()
                input.navDown()
                try await waitUntil(timeout: .seconds(2)) { stage.choices.last?.isSelected == true }
                input.select()
                try await waitUntil(timeout: .seconds(2)) { lens.page == .captureSaved }
                #expect(lens.card.elements == [.heading("Photo saved"), .body("Name it on your phone."), .meta("Tap or swipe right: all species")])
                #expect(run.sightings.unnamed.count == 1)
                #expect(try stage.album.mainContext.fetchCount(FetchDescriptor<Sighting>()) == 0)
                #expect(!speech.isListening)
                #expect(run.errorMessage == nil)
            }
        }

        @Test("silence past the limit, a recognition the mock completes, a Speech error and a tap each end on \"Photo saved\" with Speech off the session; words heard and then a pause are matched as they stand")
        func fallsBackToTheSavedPage() async throws {
            try await Self.withRun(limits: GlassesDictation.Limits(silence: .seconds(2), pause: .seconds(1))) { stage in
                let (lens, run, speech, input) = (stage.lens, stage.run, stage.speech, stage.input)
                @MainActor func backToTheList() async throws {
                    try await waitUntil(timeout: .seconds(5)) { !speech.isListening }
                    input.navRight()
                    try await waitUntil(timeout: .seconds(2)) { lens.page == .list }
                }

                // Nothing is said.
                try await stage.askForAName()
                try await waitUntil(timeout: .seconds(6)) { lens.page == .captureSaved }
                #expect(run.sightings.unnamed.count == 1)
                try await backToTheList()

                // The mock completes the recognition with nothing heard. Its Speech reports no state for that (found
                // here: no `.stopped` arrives), so it is the silence limit that ends the dictation; Speech stopping by
                // itself, as the docs say the glasses do, is held in `DictationProgressTests`.
                try await stage.askForAName()
                speech.simulateCompletion()
                try await waitUntil(timeout: .seconds(6)) { lens.page == .captureSaved }
                try await backToTheList()

                // A recognition error, after some words.
                try await stage.askForAName()
                speech.simulateTranscription(text: "black", isFinal: false, confidence: 0.5)
                try await waitUntil(timeout: .seconds(2)) { lens.card.elements.contains(.body("black")) }
                speech.simulateError(errorCode: 5, message: "simulated")
                try await waitUntil(timeout: .seconds(4)) { lens.page == .captureSaved }
                try await backToTheList()

                // A tap while the glasses listen: name it later.
                try await stage.askForAName()
                input.select()
                try await waitUntil(timeout: .seconds(2)) { lens.page == .captureSaved }
                try await backToTheList()

                // Words, and then nothing final: after the pause they are matched as they stand.
                try await stage.askForAName()
                speech.simulateTranscription(text: "house finch", isFinal: false, confidence: 0.5)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                #expect(stage.choices.first == LensChoiceRow(label: "House Finch", detail: "New patch", isSelected: true))
                try await backToTheList()

                #expect(run.sightings.unnamed.count == 5, "every photo is on the phone")
                #expect(try stage.album.mainContext.fetchCount(FetchDescriptor<Sighting>()) == 0)
                #expect(run.errorMessage == nil)
            }
        }

        @Test("without the glasses' microphone permission the lens goes straight to \"Photo saved\" and never listens; the phone is told to offer it, and once it is allowed the next photo is asked about")
        func withoutTheMicrophonePermission() async throws {
            try await Self.withRun { stage in
                let (lens, speech, input) = (stage.lens, stage.speech, stage.input)
                let permissions = MockDeviceKit.shared.permissions
                permissions.set(.microphone, .denied)
                permissions.setRequestResult(.microphone, result: .denied)
                defer {
                    permissions.set(.microphone, .granted)
                    permissions.setRequestResult(.microphone, result: .granted)
                }
                #expect(!stage.glassesRun.dictationNeedsPermission)

                try await stage.takePhoto()
                try await waitUntil(timeout: .seconds(5)) { lens.page != .captureSaving }
                #expect(lens.page == .captureSaved, "not by way of \"Say the bird's name\"")
                #expect(!speech.isListening)
                #expect(stage.glassesRun.dictationNeedsPermission)
                #expect(stage.run.sightings.unnamed.count == 1)

                // The phone's offer, refused in Meta AI, still stands; allowed, it goes.
                #expect(await stage.glassesRun.allowDictation() == false)
                #expect(stage.glassesRun.dictationNeedsPermission)
                permissions.setRequestResult(.microphone, result: .granted)
                permissions.set(.microphone, .granted)
                #expect(await stage.glassesRun.allowDictation())
                #expect(!stage.glassesRun.dictationNeedsPermission)

                input.select()
                try await waitUntil(timeout: .seconds(2)) { lens.page == .list }
                try await stage.askForAName()
                #expect(lens.page == .captureNaming)
            }
        }

        @Test("with the switch off the camera stream comes off the session while the glasses listen, and goes back when they stop")
        func streamOffForTheDictation() async throws {
            try await Self.withRun(keepsStream: false) { stage in
                let (lens, speech) = (stage.lens, stage.speech)
                try await stage.askForAName()
                #expect(stage.source.dictationHolds == 1)
                #expect(stage.source.dictationReleases == 0)
                speech.simulateTranscription(text: "house finch", isFinal: true, confidence: 0.9)
                try await waitUntil(timeout: .seconds(5)) { lens.page == .captureMatches }
                try await waitUntil(timeout: .seconds(5)) { stage.source.dictationReleases == 1 }
                #expect(!speech.isListening)
                #expect(stage.source.dictationHolds == 1)
            }
        }

        @Test("the glasses come off while the lens listens for a name: Speech goes with the session, and the pages come back on \"Photo saved\"")
        func doffWhileListening() async throws {
            try await Self.withRun { stage in
                let (lens, glasses) = (stage.lens, stage.glasses)
                try await stage.askForAName()
                glasses.doff()
                try await waitUntil { Wearables.shared.deviceForIdentifier(glasses.deviceIdentifier)?.donState == .doffed }
                glasses.powerOff()
                try await waitUntil { stage.glassesRun.phase == .paused(.glassesOff) }
                #expect(lens.phase == .suspended)
                #expect(lens.page == .captureSaved, "nobody is there to say a name")
                #expect(stage.run.sightings.unnamed.count == 1)

                glasses.powerOn()
                glasses.don()
                try await waitUntil(timeout: .seconds(30)) { stage.glassesRun.phase == .listening }
                #expect(lens.page == .captureSaved)
                #expect(!stage.speech.isListening)
                try await waitUntil { lens.inputsState == .active }
                stage.input.select()
                try await waitUntil(timeout: .seconds(2)) { lens.page == .list }
                // The next photo is asked about on the new session.
                try await stage.askForAName()
            }
        }
    }
}

/// How many times something was read, counted from wherever it was read.
private nonisolated final class ReadCount: Sendable {
    private let reads = Mutex(0)

    func add() {
        reads.withLock { $0 += 1 }
    }

    var count: Int {
        reads.withLock { $0 }
    }
}
