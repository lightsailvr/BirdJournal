import Foundation
import Photos
import Testing
@testable import BirdJournal

// Issue #192 (of #185): every photo taken with the capture camera is also saved to the birder's Photos library. The app asks
// to add to the library, and only to add, the first time; a no is final and costs the capture nothing; and a photo that came
// from the library is not saved back into it. The library is a stand-in here: the simulator's prompt can't be answered by a
// test, and nothing should be written to a real library by one.
@Suite("Copies to Photos")
@MainActor
struct PhotosCopiesTests {
    static func cameraPhoto(_ bytes: [UInt8] = [1, 2, 3]) -> CapturedPhoto {
        CapturedPhoto(data: Data(bytes), takenAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("the first photo the camera takes asks to add to Photos, a yes saves it as it came, and the next is saved without asking")
    func askedOnceThenSaved() async {
        let library = StandInPhotosLibrary(access: .notAsked, answer: .allowed)
        let copies = PhotosCopies(library: library)

        #expect(await copies.keep(Self.cameraPhoto([1, 2, 3])) == .saved)
        #expect(library.timesAsked == 1)
        #expect(library.added == [Data([1, 2, 3])], "the camera's own bytes")

        #expect(await copies.keep(Self.cameraPhoto([4, 5])) == .saved)
        #expect(library.timesAsked == 1)
        #expect(library.added == [Data([1, 2, 3]), Data([4, 5])])
    }

    @Test("a no saves nothing and is not asked again: not for the next photo, and not at the next launch")
    func refusedOnce() async {
        let library = StandInPhotosLibrary(access: .notAsked, answer: .refused)
        let copies = PhotosCopies(library: library)

        #expect(await copies.keep(Self.cameraPhoto()) == .notAllowed)
        #expect(await copies.keep(Self.cameraPhoto()) == .notAllowed)
        #expect(library.timesAsked == 1)
        #expect(library.added.isEmpty)

        // The next launch: the phone remembers the answer, and the app doesn't raise it.
        let later = StandInPhotosLibrary(access: .refused, answer: .allowed)
        #expect(await PhotosCopies(library: later).keep(Self.cameraPhoto()) == .notAllowed)
        #expect(later.timesAsked == 0)
        #expect(later.added.isEmpty)
    }

    @Test("two photos taken while the question is still up are one question")
    func oneQuestionAtATime() async {
        let library = StandInPhotosLibrary(access: .notAsked, answer: .allowed)
        let copies = PhotosCopies(library: library)

        async let first = copies.keep(Self.cameraPhoto([1]))
        async let second = copies.keep(Self.cameraPhoto([2]))
        let outcomes = await [first, second]

        #expect(outcomes == [.saved, .saved])
        #expect(library.timesAsked == 1)
        #expect(Set(library.added) == [Data([1]), Data([2])])
    }

    @Test("a photo chosen from the library is not saved back into it, and nothing is asked for it")
    func libraryPhotosStayWhereTheyAre() async throws {
        let library = StandInPhotosLibrary(access: .notAsked, answer: .allowed)
        let chosen = try #require(CapturedPhoto.chosenFromLibrary(DebugSeeds.frameJPEG()))

        #expect(await PhotosCopies(library: library).keep(chosen) == .notTheCameras)
        #expect(library.timesAsked == 0)
        #expect(library.added.isEmpty)
    }

    @Test("a copy Photos won't take is a copy lost and nothing more")
    func aFailedCopy() async {
        let library = StandInPhotosLibrary(access: .allowed, fails: true)

        #expect(await PhotosCopies(library: library).keep(Self.cameraPhoto()) == .failed)
        #expect(library.added.isEmpty)
    }

    @Test("in the app that hosts these tests a copy goes to a stand-in, so a screen under test that presses the shutter never raises the simulator's question", .timeLimit(.minutes(1)))
    func theTestHostsLibrary() async {
        // The simulator's own library would leave this waiting on its question, or refuse.
        #expect(await PhotosCopies.forApp.keep(Self.cameraPhoto()) == .saved)
    }

    @Test("the phone's answers: undecided is not asked yet, allowed is allowed, and a no or a restriction is a refusal")
    func thePhonesAnswers() {
        #expect(SystemPhotosLibrary.access(.notDetermined) == .notAsked)
        #expect(SystemPhotosLibrary.access(.authorized) == .allowed)
        #expect(SystemPhotosLibrary.access(.limited) == .allowed)
        #expect(SystemPhotosLibrary.access(.denied) == .refused)
        #expect(SystemPhotosLibrary.access(.restricted) == .refused)
    }

    @Test("the question the phone asks says why: the app's text for adding to Photos is there, and says it only adds")
    func thePermissionText() throws {
        let text = try #require(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)
        #expect(text.hasPrefix("Featherguild saves a copy of each photo you take with its camera"), "\(text)")
        #expect(text.contains("can't see"), "add-only: \(text)")
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") == nil, "the app never asks to read the library")
    }
}
