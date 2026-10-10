import Identification
import Testing
@testable import LensSession

// Issue #41, phase 4: the sounds page (swipe up from the photo) has the play control. A tap plays the species'
// song, the next tap while it plays stops it, and the tap after that plays the call; any swipe, a problem page or
// the end of the run stops it. A tap on the photo page plays nothing, since the band can read a swipe there as a
// tap; the details page keeps its tap ("Add to my list").
@Suite("Lens reference sounds")
struct LensSoundTests {
    /// A machine on the phoebe's sounds page (index 0); the phoebe has a song and a call.
    static func onPhoebe() -> LensStateMachine {
        var machine = LensStateMachine()
        machine.update(with: Fakes.stack(3), at: Fakes.quiet)
        _ = machine.apply(.tap)
        _ = machine.apply(.swipeUp)
        precondition(machine.page == .sounds(index: 0))
        return machine
    }

    @Test("a tap plays the song, a tap while it plays stops it, and the next tap plays the call, then the song again")
    func tapCycles() throws {
        var machine = Self.onPhoebe()
        let candidate = Fakes.candidate(Fakes.phoebe)

        let first = machine.apply(.tap, sounds: Fakes.sounds)
        let song = try #require(machine.playing)
        #expect(song.index == 0)
        #expect(song.sound == Fakes.phoebeSong)
        #expect(!song.onPhone)
        #expect(first == .playSound(candidate, song))
        #expect(machine.page == .sounds(index: 0))

        let stop = machine.apply(.tap, sounds: Fakes.sounds)
        #expect(stop == .stopSound)
        #expect(machine.playing == nil)

        _ = machine.apply(.tap, sounds: Fakes.sounds)
        #expect(machine.playing?.sound == Fakes.phoebeCall)
        let ended = machine.soundEnded(machine.playing!.id)
        #expect(ended)
        #expect(machine.playing == nil)

        _ = machine.apply(.tap, sounds: Fakes.sounds)
        #expect(machine.playing?.sound == Fakes.phoebeSong, "wraps round to the song")
    }

    @Test("every start is a new playback, so a late end of an earlier clip leaves the current one alone")
    func staleEndIgnored() throws {
        var machine = Self.onPhoebe()
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        let first = try #require(machine.playing)
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        let second = try #require(machine.playing)
        #expect(first.id != second.id)

        let staleEnd = machine.soundEnded(first.id)
        #expect(!staleEnd)
        let staleRoute = machine.soundPlaysOnPhone(first.id)
        #expect(!staleRoute)
        #expect(machine.playing == second)

        let routed = machine.soundPlaysOnPhone(second.id)
        #expect(routed)
        #expect(machine.playing?.onPhone == true)
    }

    @Test("a tap on the photo page plays nothing, even for a species with clips")
    func photoTapIsQuiet() {
        var machine = Self.onPhoebe()
        _ = machine.apply(.swipeDown)
        #expect(machine.page == .species(index: 0))
        #expect(machine.apply(.tap, sounds: Fakes.sounds) == nil)
        #expect(machine.playing == nil)
        #expect(machine.nextSounds.isEmpty)
    }

    @Test("a species without clips ignores the tap, so nothing is played or added")
    func noClips() {
        var machine = Self.onPhoebe()
        _ = machine.apply(.swipeLeft)
        _ = machine.apply(.swipeUp)
        #expect(machine.page == .sounds(index: 1))
        let effect = machine.apply(.tap, sounds: Fakes.sounds)
        #expect(effect == nil)
        #expect(machine.playing == nil)
        #expect(machine.savedIndices.isEmpty)
    }

    @Test("any swipe or Back stops the clip and still moves the page", arguments: [
        (LensGesture.swipeLeft, LensPage.species(index: 1)),
        (.swipeRight, .list),
        (.swipeDown, .species(index: 0)),
        (.swipeUp, .sounds(index: 0)),
        (.back, .list),
    ])
    func swipeStops(gesture: LensGesture, page: LensPage) {
        var machine = Self.onPhoebe()
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        let effect = machine.apply(gesture, sounds: Fakes.sounds)
        #expect(effect == .stopSound)
        #expect(machine.playing == nil)
        #expect(machine.page == page)
    }

    @Test("a problem page over a playing clip stops it")
    func problemStops() {
        var machine = Self.onPhoebe()
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        let stop = machine.report(.connectionLost)
        #expect(stop == .stopSound)
        #expect(machine.playing == nil)
        let again = machine.report(.noLocation)
        #expect(again == nil)
    }

    @Test("the details page's tap still opens the viewfinder to add the bird and plays nothing")
    func detailsTapSaves() {
        var machine = Self.onPhoebe()
        _ = machine.apply(.swipeDown)
        _ = machine.apply(.swipeDown)
        let effect = machine.apply(.tap, sounds: Fakes.sounds)
        #expect(effect == .openViewfinder(Fakes.candidate(Fakes.phoebe)))
        #expect(machine.playing == nil)
    }

    @Test("a stack from a new session stops the clip with everything else")
    func newSessionStops() {
        var machine = Self.onPhoebe()
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        machine.update(with: CandidateStack(candidates: [Fakes.candidate(Fakes.towhee)]), at: Fakes.quiet)
        #expect(machine.playing == nil)
        #expect(machine.page == .list)
    }

    // MARK: - The pages' hints

    static func render(_ machine: LensStateMachine) -> LensCard {
        LensCardRenderer.render(
            machine.page, stack: machine.stack, order: machine.order, selection: machine.selection, saved: machine.savedIndices,
            playing: machine.playing, nextSounds: machine.nextSounds
        ) { species in
            var profile = Fakes.phoebeProfile
            profile.sounds = Fakes.sounds(species)
            return profile
        }
    }

    @Test("the photo page of a species with clips points up to its sounds")
    func photoHint() {
        var machine = Self.onPhoebe()
        _ = machine.apply(.swipeDown)
        #expect(Self.render(machine).elements.last == .meta("Up: its sounds · down: more · right: all species"))
    }

    @Test("the sounds page marks and names the clip a tap plays, then what is playing and where, then the next clip")
    func hint() throws {
        var machine = Self.onPhoebe()
        var card = Self.render(machine)
        #expect(card.elements.first == .title("Black Phoebe", detail: "80% match"))
        #expect(card.elements.contains(.sounds([
            LensSoundRow(label: "Song", isNext: true, isPlaying: false),
            LensSoundRow(label: "Call", isNext: false, isPlaying: false),
        ])))
        #expect(card.elements.last == .meta("Tap: play its song · down: photo"))

        _ = machine.apply(.tap, sounds: Fakes.sounds)
        card = Self.render(machine)
        #expect(card.elements.contains(.sounds([
            LensSoundRow(label: "Song", isNext: false, isPlaying: true),
            LensSoundRow(label: "Call", isNext: false, isPlaying: false),
        ])))
        #expect(card.elements.last == .meta("Playing song… tap to stop"))
        let routed = machine.soundPlaysOnPhone(machine.playing!.id)
        #expect(routed)
        #expect(Self.render(machine).elements.last == .meta("Song on the phone… tap to stop"))

        let ended = machine.soundEnded(machine.playing!.id)
        #expect(ended)
        #expect(Self.render(machine).elements.last == .meta("Tap: play its call · down: photo"))
    }

    @Test("the sounds page credits the clip a tap plays next, or the one playing")
    func credit() {
        var machine = Self.onPhoebe()
        let credited: (Species) -> SpeciesProfile? = { species in
            var profile = Fakes.phoebeProfile
            profile.sounds = Fakes.sounds(species).map { LensSound(id: $0.id, kind: $0.kind, credit: "Sound: Recordist, \($0.id)") }
            return profile
        }
        let render = {
            LensCardRenderer.render(machine.page, stack: machine.stack, order: machine.order, selection: machine.selection, saved: [], playing: machine.playing, nextSounds: machine.nextSounds, profile: credited)
        }
        #expect(render().elements.contains(.meta("Sound: Recordist, xc-1")))
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        #expect(render().elements.contains(.meta("Sound: Recordist, xc-2")))
    }

    @Test("the sounds page with clips stays inside the word budget while playing")
    func hintBudget() {
        var machine = Self.onPhoebe()
        _ = machine.apply(.tap, sounds: Fakes.sounds)
        _ = machine.soundPlaysOnPhone(machine.playing!.id)
        #expect(Self.render(machine).wordCount <= LensCardRenderer.wordBudget)
    }
}
