import UIKit
import XCTest

/// Issue #222 (of #206): a sighting saved with no location is outside every set, and its patch is the app's generic embroidered
/// patch with the bird's name, never an empty blank. Real taps on the running app, on a bird no pack describes.
final class UnchartedPatchUITests: XCTestCase {
    private static let name = "Common Blackbird"

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedNoLocation", "Turdus merula_\(Self.name)"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The share of the picture's pixels that are brown thread, in the part of it between these fractions. Thread is told from
    /// canvas by how much of its colour is colour: the canvas is pale all over, lit or drawn as the blank, dark only in the
    /// shade of its weave, and the feather's vane is brown.
    private func brownThread(_ shot: XCUIScreenshot, columns: ClosedRange<Double>, rows: ClosedRange<Double>) throws -> Double {
        let cg = try XCTUnwrap(shot.image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var dark = 0, counted = 0
        for y in Int(rows.lowerBound * Double(cg.height))..<Int(rows.upperBound * Double(cg.height)) {
            for x in Int(columns.lowerBound * Double(cg.width))..<Int(columns.upperBound * Double(cg.width)) {
                let at = (y * cg.width + x) * 4
                counted += 1
                let (most, least) = (max(bytes[at], bytes[at + 1], bytes[at + 2]), min(bytes[at], bytes[at + 1], bytes[at + 2]))
                if Double(most - least) > 0.45 * Double(most) { dark += 1 }
            }
        }
        return Double(dark) / Double(max(counted, 1))
    }

    @MainActor
    func testASightingWithNoLocationShowsTheGenericPatchWithTheBirdsNameAndUnchartedOutsideEverySet() throws {
        let app = launch(["-autoBoard", "uncharted", "-autoScreen", "cards"])
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(Self.name), Uncharted patch, seen once")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(tile.label.contains("art on its way"), tile.label)
        XCTAssertTrue(app.staticTexts["1 outside every set"].exists, "screen: \(app.debugDescription.prefix(3000))")
        // Where the paper tag hangs: the tag takes no touch of its own.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        let face = element(app, "patch-face")
        XCTAssertTrue(face.waitForExistence(timeout: 10), "the tile opened its page: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(face.label.hasPrefix("\(Self.name), Uncharted patch, seen once"), face.label)
        XCTAssertTrue(app.staticTexts[Self.name].exists, "the bird's name under its patch: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Uncharted"].exists, "its edition line: \(app.debugDescription.prefix(3000))")
        // Past the page's push and the patch's decode. The patch is the middle 286 points of the face's 330 by 470, and the
        // feather's dark end lies right of centre, about three quarters of the way down it.
        Thread.sleep(forTimeInterval: 3)
        let shot = face.screenshot()
        add(XCTAttachment(screenshot: shot))
        let feather = try brownThread(shot, columns: 0.50...0.74, rows: 0.63...0.69)
        XCTAssertGreaterThan(feather, 0.4, "the feather is embroidered where a blank has bare canvas")
        let canvas = try brownThread(shot, columns: 0.30...0.70, rows: 0.50...0.58)
        XCTAssertLessThan(canvas, 0.05, "the control: bare canvas between the tag and the feather")

        // It turns over like any patch, from the tag too, to a complete card.
        face.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)).tap()
        let heading = element(app, "card-heading")
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(heading.label, "Uncharted, outside every set", "VoiceOver's reading of \"Uncharted · outside every set\"")
        XCTAssertEqual(element(app, "card-name").label, Self.name)
        XCTAssertTrue(element(app, "card-history").exists)
        XCTAssertEqual(element(app, "card-art-credit").label, "AI illustration", "the generic patch is one")
    }

    @MainActor
    func testAnUnchartedAddStillGoesStraightToItsFinishedPatchWithNoStitching() throws {
        // A stitch-in this slow would still be on the page when it's looked at.
        let app = launch(["-autoScreen", "reveal", "-stitchInSeconds", "60"])
        let revealed = element(app, "revealed-patch")
        XCTAssertTrue(revealed.waitForExistence(timeout: 15), "the finished page: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "no stitching for the generic patch")
        XCTAssertTrue(app.staticTexts[Self.name].exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["New patch, Uncharted"].exists, "screen: \(app.debugDescription.prefix(3000))")
        Thread.sleep(forTimeInterval: 2)
        add(XCTAttachment(screenshot: revealed.screenshot()))
    }
}
