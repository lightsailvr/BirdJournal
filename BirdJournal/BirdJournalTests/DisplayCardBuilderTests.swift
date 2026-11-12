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
        .captureSaving, .captureCancel, .captureSaved, .captureNaming, .captureMatches, .captureAdded, .problem(.photoNotTaken),
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

    @Test("the photo on \"Say the bird's name\" is the journal's crop of the picture in the middle of a canvas of the card's width, whatever the picture's shape; data that is no picture gives none")
    func capturedPhoto() throws {
        for size in [CGSize(width: 1080, height: 1440), CGSize(width: 360, height: 640), CGSize(width: 4032, height: 3024), CGSize(width: 64, height: 64)] {
            let jpeg = try #require(Self.picture(size, .blue).jpegData(compressionQuality: 0.9))
            let image = try #require(DisplayCardBuilder.capturedPhotoImage(jpeg))
            #expect(image.scale == 1)
            // The glasses stretch a `.fill` image to the card's width, so a narrower one would grow off the lens.
            #expect(image.size == DisplayCardBuilder.capturedPhotoSize, "\(size) became \(image.size)")
            let crop = FrameCrop.centerRect(in: size)
            let scale = min(DisplayCardBuilder.capturedPhotoSize.width / crop.width, DisplayCardBuilder.capturedPhotoSize.height / crop.height, 1)
            let lit = try Self.litBounds(of: image)
            #expect(abs(lit.width - crop.width * scale) <= 2 && abs(lit.height - crop.height * scale) <= 2, "the crop's size: \(lit) for \(crop.size) at \(scale)")
            #expect(abs(lit.midX - image.size.width / 2) <= 2 && abs(lit.midY - image.size.height / 2) <= 2, "in the middle: \(lit)")
        }
        #expect(DisplayCardBuilder.capturedPhotoImage(Data("not a picture".utf8)) == nil)
    }

    @Test("the mark of a photo being taken is as wide as the card, so the glasses draw it at its size, and is lit")
    func shutterMark() throws {
        let image = DisplayCardBuilder.shutterImage
        #expect(image.scale == 1)
        #expect(image.size.width == DisplayCardBuilder.capturedPhotoSize.width)
        let lit = try Self.litBounds(of: image)
        #expect(lit.width > image.size.width * 0.9 && lit.height > image.size.height * 0.8, "the corners reach the edges: \(lit)")
    }

    @Test("the viewfinder's picture is a canvas of the card's width with the journal's crop whole on it, whatever the frame's size")
    func viewfinderPicture() throws {
        for size in [CGSize(width: 360, height: 640), CGSize(width: 504, height: 896), CGSize(width: 720, height: 1280), CGSize(width: 640, height: 360)] {
            let image = DisplayCardBuilder.viewfinderImage(Self.picture(size, .blue))
            #expect(image.scale == 1)
            #expect(image.size == DisplayCardBuilder.viewfinderSize, "\(size) became \(image.size)")
            let lit = try Self.litBounds(of: image)
            let kept = FrameCrop.centerRect(in: size)
            let scale = min(image.size.height * DisplayCardBuilder.viewfinderCropShare / kept.height, image.size.width * DisplayCardBuilder.viewfinderCropShare / kept.width)
            // The crop is whole on the canvas, and the frame around it reaches as far as the canvas lets it.
            #expect(kept.width * scale <= image.size.width && kept.height * scale <= image.size.height)
            #expect(abs(lit.width - min(size.width * scale, image.size.width)) <= 2, "\(size): \(lit)")
            #expect(abs(lit.height - min(size.height * scale, image.size.height)) <= 2, "\(size): \(lit)")
            #expect(abs(lit.midX - image.size.width / 2) <= 2 && abs(lit.midY - image.size.height / 2) <= 2, "in the middle: \(lit)")
        }
    }

    /// A picture of one colour, one pixel a point.
    private static func picture(_ size: CGSize, _ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// The box around every pixel of `image` that is not black: where the canvas has a picture.
    private static func litBounds(of image: UIImage) throws -> CGRect {
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 24 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= 0, "nothing lit")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
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
