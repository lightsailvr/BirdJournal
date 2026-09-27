import Identification
import LensSession
import MWDATDisplay
import Testing
import UIKit
@testable import BirdJournal

// Spec "Testing: Card renderer": every page becomes one Display tree with a single root. The DSL is opaque, so the
// root is asserted by type (`flexBox(for:)` returns exactly one `FlexBox`) and the builder is run over every page
// the renderer produces, with and without a loadable photo.
@Suite("DisplayCardBuilder")
struct DisplayCardBuilderTests {
    static let stack = FakeLensStack.stack(count: 5) // The fifth species has no profile.

    nonisolated static let pages: [LensPage] = [
        .listening, .photo(index: 0), .photo(index: 4), .description(index: 0), .description(index: 4),
        .confirm(index: 0), .saved(index: 0),
    ]

    @Test("every page builds one root FlexBox", arguments: pages)
    func oneRoot(page: LensPage) {
        let card = LensCardRenderer.render(page, stack: Self.stack, profile: FakeLensStack.profile(for:))
        let root: FlexBox = DisplayCardBuilder.flexBox(for: card, image: FakeLensStack.image(for:)) { _ in }
        _ = root
    }

    @Test("a photo the app cannot load still builds a card")
    func missingPhoto() {
        let card = LensCardRenderer.render(.photo(index: 0), stack: Self.stack, profile: FakeLensStack.profile(for:))
        #expect(card.photo != nil)
        let root: FlexBox = DisplayCardBuilder.flexBox(for: card, image: { _ in nil }) { _ in }
        _ = root
    }

    @Test("the fake stack loads a photo for every profile and none for an unknown name")
    func fakeImages() throws {
        for profile in FakeLensStack.profiles.values {
            #expect(FakeLensStack.image(for: try #require(profile.photo)) != nil)
        }
        #expect(FakeLensStack.image(for: LensImage(id: "nope")) == nil)
    }
}
