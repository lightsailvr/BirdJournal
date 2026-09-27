import Identification
import LensSession
import MWDATDisplay
import Testing
import UIKit
@testable import BirdJournal

// Spec "Testing: Card renderer": every screenful becomes one Display tree with a single root. The DSL is opaque, so
// the root is asserted by type (`flexBox(for:)` returns exactly one `FlexBox`) and the builder is run over every
// screenful of every page the renderer produces, with and without a loadable photo, saved and not.
@Suite("DisplayCardBuilder")
struct DisplayCardBuilderTests {
    static let stack = FakeLensStack.stack(count: 5) // The fifth species has no profile.

    nonisolated static let pages: [LensPage] = [.list(screenful: 0), .species(index: 0, screenful: 0), .species(index: 4, screenful: 0)]

    @Test("every screenful of every page builds one root FlexBox, saved or not", arguments: pages, [Set<Int>(), [0, 4]])
    func oneRoot(page: LensPage, saved: Set<Int>) {
        let card = LensCardRenderer.render(page, stack: Self.stack, saved: saved, profile: FakeLensStack.profile(for:))
        for screenful in card.screenfuls {
            let root: FlexBox = DisplayCardBuilder.flexBox(for: screenful, image: FakeLensStack.image(for:)) { _ in }
            _ = root
        }
    }

    @Test("a photo the app cannot load still builds a card")
    func missingPhoto() {
        let card = LensCardRenderer.render(.species(index: 0, screenful: 0), stack: Self.stack, saved: [], profile: FakeLensStack.profile(for:))
        #expect(card.photo != nil)
        let root: FlexBox = DisplayCardBuilder.flexBox(for: card.screenful(at: 0), image: { _ in nil }) { _ in }
        _ = root
    }

    @Test("the fake stack loads a card-width photo for every profile and none for an unknown name")
    func fakeImages() throws {
        for profile in FakeLensStack.profiles.values {
            let photo = try #require(profile.photo)
            let image = try #require(FakeLensStack.image(for: photo))
            #expect(image.size == CGSize(width: 552, height: 368))
            #expect(image.size.width == 600 - 2 * DisplayCardBuilder.padding)
        }
        #expect(FakeLensStack.image(for: LensImage(id: "nope")) == nil)
    }
}
