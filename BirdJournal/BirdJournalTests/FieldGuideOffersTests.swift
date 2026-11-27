import Album
import Foundation
import Pack
import Testing
@testable import BirdJournal

/// Issue #223 (of #206): a birder standing in a set whose field guide isn't on the phone is offered its download, once per
/// set. The phone here has no bundled pack: the pack that ships in the app stands in for a field guide that can be
/// downloaded, and a made-up set for another one, so no place or bird is named.
@Suite("Field-guide offers", .serialized)
@MainActor
struct FieldGuideOffersTests {
    /// Another set the index offers a field guide for.
    static let elsewhere = "test-elsewhere"

    /// A phone whose index offers two field guides, with neither on it yet.
    struct Phone {
        let phone: PlacementOnThePhoneTests.Phone
        let suite = "field-guide-offers-\(UUID().uuidString)"
        var here: String { phone.fieldGuide.info.id }

        init() throws {
            phone = try PlacementOnThePhoneTests.Phone()
            let guide = phone.fieldGuide.info
            try phone.storage.cacheIndex(PackIndex(packs: [
                PackDescriptor(id: guide.id, name: guide.name, version: guide.version, url: URL(string: "https://example.invalid/here.zip")!, sha256: "", byteCount: 173_000_000),
                PackDescriptor(id: FieldGuideOffersTests.elsewhere, name: "Elsewhere", version: 1, url: URL(string: "https://example.invalid/elsewhere.zip")!, sha256: "", byteCount: 64_000_000),
            ]))
        }

        /// The offers as a launch makes them, for a birder standing in `place`.
        @MainActor
        func offers(standingIn place: String?) -> FieldGuideOffers {
            FieldGuideOffers(library: phone.library(), place: { place }, defaults: UserDefaults(suiteName: suite)!)
        }

        func remove() {
            phone.remove()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    @Test("standing in a set whose field guide isn't on the phone, the birder is offered its download, with its size")
    func offeredWhereTheBirderIs() throws {
        let phone = try Phone()
        defer { phone.remove() }

        let offer = try #require(phone.offers(standingIn: phone.here).here)

        #expect(offer.id == phone.here)
        #expect(offer.byteCount == 173_000_000)
    }

    @Test("a dismissal is remembered across launches, for that set only")
    func aDismissalIsRemembered() throws {
        let phone = try Phone()
        defer { phone.remove() }
        let offers = phone.offers(standingIn: phone.here)

        offers.dismiss(setID: phone.here)

        #expect(offers.here == nil, "gone at once")
        #expect(phone.offers(standingIn: phone.here).here == nil, "and at the next launch")
        #expect(phone.offers(standingIn: Self.elsewhere).here?.id == Self.elsewhere, "another set's offer is its own")
        #expect(phone.offers(standingIn: Self.elsewhere).here?.byteCount == 64_000_000)
    }

    @Test("nothing is offered outside every set, or once the field guide is on the phone")
    func nothingToOffer() throws {
        let phone = try Phone()
        defer { phone.remove() }
        #expect(phone.offers(standingIn: nil).here == nil, "outside every set")

        try phone.phone.download()

        #expect(phone.offers(standingIn: phone.here).here == nil, "the place's field guide is on the phone")
        #expect(phone.offers(standingIn: Self.elsewhere).here != nil, "the other still isn't")
    }
}
