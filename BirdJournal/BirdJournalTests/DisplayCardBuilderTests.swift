import Album
import Identification
import LensSession
import MWDATDisplay
import Testing
import UIKit
@testable import BirdJournal

// Spec "Testing: Card renderer": every page becomes one Display tree with a single root. The DSL is opaque, so the
// root is asserted by type (`flexBox(for:)` returns exactly one `FlexBox`) and the builder is run over every page
// the renderer produces, with and without a loadable photo, saved and not.
@Suite("DisplayCardBuilder")
struct DisplayCardBuilderTests {
    static let stack = FakeLensStack.stack(count: 5) // The fifth species has no profile.
    /// The order at the fake stack's own clock: the bushtit and the hummingbird calling, so the list has marked rows
    /// and the other cards name the caller.
    static let order: SpeciesListOrder = {
        var order = SpeciesListOrder()
        order.update(with: stack, at: FakeLensStack.time(count: 5))
        return order
    }()

    nonisolated static let pages: [LensPage] = [
        .list, .species(index: 0), .species(index: 4), .details(index: 0), .details(index: 4),
        .captureViewfinder, .captureSaving, .captureSaved, .captureNaming, .captureMatches, .captureAdded, .problem(.photoNotTaken),
    ]

    @Test("every page builds one root FlexBox, saved or not, with the card each add earned", arguments: pages, [Set<Int>(), [0, 4]])
    func oneRoot(page: LensPage, saved: Set<Int>) {
        let earned: [Int: LensEarnedPatch] = saved.isEmpty ? [:] : [0: .newPatch, 4: .seenAgain(count: 3)]
        let card = LensCardRenderer.render(page, stack: Self.stack, order: Self.order, selection: 4, saved: saved, earned: earned, profile: FakeLensStack.profile(for:))
        if page == .list {
            #expect(card.elements[2] == .capture(label: "Capture a sighting", isSelected: false))
            guard case .list(let rows) = card.elements[3] else { Issue.record("no rows on the list"); return }
            #expect(rows.map(\.isCalling) == [true, true, false, false, false])
        }
        let root: FlexBox = DisplayCardBuilder.flexBox(for: card, image: FakeLensStack.image(for:)) { _ in }
        _ = root
    }

    @Test("the list builds with the highlight on the capture row, with birds and without (issue #193)")
    func captureRowHighlighted() {
        for stack in [Self.stack, CandidateStack()] {
            var order = SpeciesListOrder()
            order.update(with: stack, at: FakeLensStack.quiet)
            let card = LensCardRenderer.render(.list, stack: stack, order: order, selection: 0, captureSelected: true, saved: [], profile: FakeLensStack.profile(for:))
            #expect(card.elements[2] == .capture(label: "Capture a sighting", isSelected: true))
            let root: FlexBox = DisplayCardBuilder.flexBox(for: card, image: FakeLensStack.image(for:)) { _ in }
            _ = root
        }
    }

    @Test("the pages a photo is named on build one root each: listening with the photo and without, the birds, no bird, and added (issue #194)")
    func namingPages() throws {
        var listening = LensNaming(capture: 1, dictation: 1)
        listening.heard = "black pho"
        var listed = listening
        listed.matches = [LensNameMatch(id: "Sayornis nigricans", commonName: "Black Phoebe", isNewPatch: true), LensNameMatch(id: "Sayornis saya", commonName: "Say's Phoebe", isNewPatch: false)]
        listed.highlight = 1
        var none = listening
        none.heard = "flibber"
        let named = LensNamedCapture(commonName: "Black Phoebe", place: "Los Angeles", earned: .newPatch)
        let photo = try #require(DisplayCardBuilder.capturedPhotoImage(DebugSeeds.frameJPEG()))
        for (page, naming) in [(LensPage.captureNaming, listening), (.captureMatches, listed), (.captureMatches, none), (.captureAdded, listening)] {
            let card = LensCardRenderer.render(page, stack: Self.stack, order: Self.order, selection: 0, saved: [], naming: naming, named: named, profile: FakeLensStack.profile(for:))
            #expect(card.screenfuls.count == 1)
            for capturedPhoto in [photo, nil] {
                let root: FlexBox = DisplayCardBuilder.flexBox(for: card, image: FakeLensStack.image(for:), capturedPhoto: capturedPhoto) { _ in }
                _ = root
            }
        }
    }

    @Test("the photo on \"Say the bird's name\" is the journal's crop of the picture, no larger than its box, whatever the picture's shape; data that is no picture gives none")
    func capturedPhoto() throws {
        for size in [CGSize(width: 1080, height: 1440), CGSize(width: 360, height: 640), CGSize(width: 4032, height: 3024), CGSize(width: 64, height: 64)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let jpeg = try #require(UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }.jpegData(compressionQuality: 0.9))
            let image = try #require(DisplayCardBuilder.capturedPhotoImage(jpeg))
            #expect(image.scale == 1)
            #expect(image.size.width <= DisplayCardBuilder.capturedPhotoSize.width && image.size.height <= DisplayCardBuilder.capturedPhotoSize.height, "\(size) became \(image.size)")
            #expect(image.size.width > 0 && image.size.height > 0)
            let crop = FrameCrop.centerRect(in: size)
            #expect(abs(image.size.width / image.size.height - crop.width / crop.height) < 0.05, "the crop's shape: \(image.size) for \(crop.size)")
        }
        #expect(DisplayCardBuilder.capturedPhotoImage(Data("not a picture".utf8)) == nil)
    }

    @Test("a photo the app cannot load still builds a card")
    func missingPhoto() {
        let card = LensCardRenderer.render(.species(index: 0), stack: Self.stack, order: Self.order, selection: 0, saved: [], profile: FakeLensStack.profile(for:))
        #expect(card.photo != nil)
        let root: FlexBox = DisplayCardBuilder.flexBox(for: card, image: { _ in nil }) { _ in }
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
