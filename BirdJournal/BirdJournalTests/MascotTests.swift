import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #150, slice 11: the birds in glasses as what a birder sees of them in the built app. `MascotArt` in the pack builder's
// tests holds that the pictures come from the approved patches; this holds that the build carries them as iOS needs them.
@Suite("The mascot")
@MainActor
struct MascotTests {
    /// The alpha of a picture's pixel, drawn as the app gets it from the catalog.
    private func alpha(_ image: UIImage, atX x: CGFloat, y: CGFloat) -> CGFloat {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            return format
        }())
        let picture = renderer.image { _ in
            image.draw(at: CGPoint(x: -x * image.size.width, y: -y * image.size.height))
        }
        guard let data = picture.cgImage?.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        return CGFloat(bytes[3]) / 255
    }

    @Test("Someone who chose a bird keeps it: the icons keep the names iOS remembers a choice by")
    func iconNamesStay() {
        #expect(AppIconChoice.all.map(\.name) == [
            "MyBirdJournal-RedTailedHawk", "MyBirdJournal-Default", "MyBirdJournal-GreatEgret",
            "MyBirdJournal-HouseFinch", "MyBirdJournal-ProthonotaryWarbler", "MyBirdJournal-StellersJay",
        ])
    }

    @Test("Every choice is in the build as an icon iOS can switch to")
    func everyChoiceIsInTheBuild() throws {
        let icons = try #require(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        #expect(AppIconChoice.primaryName == "MyBirdJournal-RedTailedHawk")
        for choice in AppIconChoice.all where choice.name != AppIconChoice.primaryName {
            #expect(alternates[choice.name] != nil, "\(choice.name) isn't an alternate icon")
        }
    }

    @Test("An icon's thumbnail is square and opaque to its corners", arguments: AppIconChoice.all)
    func thumbnailsAreOpaque(choice: AppIconChoice) throws {
        let image = try #require(UIImage(named: "AppIconPreview/\(choice.name)"))
        #expect(image.size.width == image.size.height)
        for (x, y) in [(0.0, 0.0), (0.99, 0.0), (0.0, 0.99), (0.99, 0.99), (0.5, 0.5)] {
            #expect(alpha(image, atX: x, y: y) == 1, "\(choice.name) shows through at \(x), \(y)")
        }
    }

    @Test("The finch is a cut patch: solid in the middle, the page showing at its corners")
    func finchIsCut() throws {
        let image = try #require(UIImage(named: "PerchedFinch"))
        #expect(alpha(image, atX: 0.5, y: 0.5) == 1)
        #expect(alpha(image, atX: 0, y: 0) == 0)
    }

    @Test("The launch screen shows the finch at the size the splash takes over at, so nothing moves between them")
    func launchScreenIsTheFinch() throws {
        let launch = try #require(Bundle.main.infoDictionary?["UILaunchScreen"] as? [String: Any])
        let name = try #require(launch["UIImageName"] as? String)
        #expect(name == "PerchedFinch")
        #expect(try #require(UIImage(named: name)).size == LaunchSplash.birdSize)
    }
}

extension AppIconChoice: CustomTestStringConvertible {
    var testDescription: String { title }
}
