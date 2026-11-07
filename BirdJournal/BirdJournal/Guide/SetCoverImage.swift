import OSLog
import Pack
import SwiftUI
import UIKit

/// A set's cover for the Atlas (issue #118 over #114's `PackLibrary.cover(setID:)`): the bundled cover, else the pack's, else
/// the index's thumbnail. Scaled to fill the frame it is given and cropped from the middle, as the covers were painted to be.
/// All five sets ship their covers (issue #150), so a set the app has no cover for, which none is today, shows the raised
/// surface rather than a drawn landscape.
struct SetCoverImage: View {
    @Environment(PackLibrary.self) private var library
    let setID: String
    @State private var image: UIImage?

    var body: some View {
        let cover = library.cover(setID: setID)
        Color.raised
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)  // a clipped picture still takes touches outside its clip
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: cover) {
                image = await Self.load(cover)
            }
    }

    /// Decodes the cover off the main actor.
    static func load(_ cover: SetCover?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let signposter = OSSignposter(subsystem: "com.matthewcelia.mybirdjournal", category: "launch")
            let state = signposter.beginInterval("Decode cover")
            defer { signposter.endInterval("Decode cover", state) }
            return decoded(cover)
        }.value
    }

    /// The cover's pixels, decoded now rather than at its first draw: a JPEG in the app, an AVIF in a pack, or the index's JPEG.
    nonisolated static func decoded(_ cover: SetCover?) -> UIImage? {
        switch cover {
        case let .bundled(_, url), let .pack(_, url):
            UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingForDisplay()
        case let .thumbnail(thumbnail):
            UIImage(data: thumbnail.thumbnail)?.preparingForDisplay()
        case nil:
            nil
        }
    }
}

/// A small deterministic generator, so a Guild or a member looks the same every time for the same ID.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a over the string's UTF-8: stable across launches, unlike `hashValue`.
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
