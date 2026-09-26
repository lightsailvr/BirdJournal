import Testing
@testable import LensSession

// Page map from DECISIONS.md, "Lens UI".
@Suite("LensNavigation")
struct LensNavigationTests {
    @Test("starts on the listening page with no species")
    func initialState() {
        let nav = LensNavigation()
        #expect(nav.page == .listening)
        #expect(nav.speciesCount == 0)
    }

    @Test("swiping on the listening page with no species stays put")
    func listeningWithoutSpecies() {
        var nav = LensNavigation()
        nav.apply(.swipeLeft)
        #expect(nav.page == .listening)
    }

    @Test("swiping left from listening opens the first species photo")
    func listeningToFirstPhoto() {
        var nav = LensNavigation()
        nav.speciesAppended()
        nav.apply(.swipeLeft)
        #expect(nav.page == .photo(index: 0))
    }

    @Test("swipe left and right move between photo pages and clamp at the ends")
    func photoPaging() {
        var nav = LensNavigation()
        nav.speciesAppended()
        nav.speciesAppended()
        nav.apply(.swipeLeft)
        nav.apply(.swipeLeft)
        #expect(nav.page == .photo(index: 1))
        nav.apply(.swipeLeft)
        #expect(nav.page == .photo(index: 1))
        nav.apply(.swipeRight)
        #expect(nav.page == .photo(index: 0))
        nav.apply(.swipeRight)
        #expect(nav.page == .listening)
    }

    @Test("swipe down opens the description, swipe up returns to the photo")
    func descriptionRoundTrip() {
        var nav = LensNavigation()
        nav.speciesAppended()
        nav.apply(.swipeLeft)
        nav.apply(.swipeDown)
        #expect(nav.page == .description(index: 0))
        nav.apply(.swipeUp)
        #expect(nav.page == .photo(index: 0))
    }

    @Test("tap on a photo confirms; swipe up from confirm returns to the photo")
    func confirmRoundTrip() {
        var nav = LensNavigation()
        nav.speciesAppended()
        nav.apply(.swipeLeft)
        nav.apply(.tap)
        #expect(nav.page == .confirm(index: 0))
        nav.apply(.swipeUp)
        #expect(nav.page == .photo(index: 0))
    }

    @Test("swipe up on a photo is in-app back to listening")
    func photoBackToListening() {
        var nav = LensNavigation()
        nav.speciesAppended()
        nav.apply(.swipeLeft)
        nav.apply(.swipeUp)
        #expect(nav.page == .listening)
    }

    @Test("new species append without moving the current photo page")
    func appendDoesNotReorder() {
        var nav = LensNavigation()
        nav.speciesAppended()
        nav.apply(.swipeLeft)
        nav.speciesAppended()
        #expect(nav.page == .photo(index: 0))
        #expect(nav.speciesCount == 2)
    }
}
