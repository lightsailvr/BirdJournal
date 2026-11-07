import Album
import Pack
import SwiftData
import SwiftUI

/// Which board the Collection shows (issue #134).
enum BoardChoice: Hashable {
    case set(id: String)
    case uncharted
}

/// How many columns a board takes (guide page 14): three, then two as the text grows, then one at accessibility sizes.
enum PatchBoardLayout {
    static func columns(for typeSize: DynamicTypeSize) -> Int {
        if typeSize.isAccessibilitySize { return 1 }
        return typeSize >= .xxLarge ? 2 : 3
    }

    static func grid(for typeSize: DynamicTypeSize, spacing: CGFloat = 14) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columns(for: typeSize))
    }
}

/// A board's patches in collector-number order, each with its count (issue #134, guide page 6). Only what you've sewn: a
/// bird you haven't found has no patch at all, as the maintainer decided on the phone. The sheet behind it is the material.
struct PatchBoard: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let patches: [CardCollection.Patch]

    /// As many as a few screens' worth: a big board's rest decode as they scroll in. Each costs about 650 KB until the cache lets go.
    private static let decodedAhead = 48

    var body: some View {
        LazyVGrid(columns: PatchBoardLayout.grid(for: typeSize), spacing: 18) {
            ForEach(patches) { patch in
                SewnPatchTile(patch: patch, name: PatchText.name(of: patch, library: library))
            }
        }
        .padding(.vertical, 14)
        .holdsPatchLight()
        .task(id: patches.map(\.id)) {
            let arts = patches.prefix(Self.decodedAhead).compactMap { library.patchArt(scientificName: $0.scientificName, setID: $0.placement.setID) }
            await PatchTextures.decodeAhead(arts, size: .thumbnail)
        }
    }
}

/// A sewn patch on a board: it rises to the touch and grows into the patch's page (issue #150, audit R1), and a long press peeks
/// at it with its quick actions.
struct SewnPatchTile: View {
    @Environment(PackLibrary.self) private var library
    let patch: CardCollection.Patch
    let name: String
    /// Under the name, in place of the number and count.
    var line: String? = nil
    /// The patch's sentence names the bird, even where the tile's words name the edition.
    var spokenName: String? = nil
    /// Where this tile is: its page's way back.
    var surface = PatchLiftSurface.board

    var body: some View {
        let state = library.patchArtState(scientificName: patch.scientificName, setID: patch.placement.setID)
        let edition = PatchEdition.of(setID: patch.placement.setID)
        NavigationLink(value: Route.patch(patch.id, from: surface)) {
            PatchTile(
                state: state, edition: edition, tag: spokenName ?? name,
                name: name, line: line ?? PatchText.tileLine(patch), spoken: PatchText.spoken(patch, name: spokenName ?? name, beingSewn: state == .beingSewn),
                lift: PatchLiftID(key: patch.id, surface: surface)
            )
        }
        .buttonStyle(.patchLift)
        .modifier(PatchPeekActions(patch: patch, surface: surface, state: state, edition: edition, tag: spokenName ?? name))
        .accessibilityHint("Opens the patch. Turn it over for its story.")
        .accessibilityIdentifier("board-patch")
    }
}

/// A patch with its words under it, in type: the name, and the number and count. Under Increase Contrast the words sit on
/// a solid surface (guide page 14).
struct PatchTile: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: PatchArtState
    let edition: PatchEdition
    /// The bird's name, for the blank's paper tag.
    let tag: String
    let name: String
    let line: String?
    /// What VoiceOver reads: the tile is one element.
    let spoken: String
    /// The tile a page grows out of: only the patch, not its words.
    var lift: PatchLiftID? = nil
    /// How wide the patch may be, in a column that's wide enough.
    var side: CGFloat = 124
    /// A Guild's boards are few patches and set their words larger than the Collection's.
    var isLarge = false

    var body: some View {
        VStack(spacing: 6) {
            PatchView(state: state, edition: edition, tag: tag)
                // One column at accessibility sizes: the patch grows with its words.
                .frame(maxWidth: typeSize.isAccessibilitySize ? 200 : side)
                .patchLiftSource(lift)
            VStack(spacing: 2) {
                Text(name)
                    .font(isLarge ? PatchFont.boardName : PatchFont.tileName)
                    .foregroundStyle(Color.ink)
                if let line {
                    Text(line)
                        .font(isLarge ? PatchFont.boardLine : PatchFont.tileLine)
                        .foregroundStyle(Color.ink)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .boardLabel()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// The type around patches (guide page 16): the system serif for names, the sans for the rest.
enum PatchFont {
    static let tileName = Font.system(.footnote, design: .serif, weight: .semibold)
    static let tileLine = Font.caption2
    /// On a Guild's boards (the reference's Compare, at 1.34).
    static let boardName = Font.system(.subheadline, design: .serif, weight: .semibold)
    static let boardLine = Font.footnote
    /// The bird's name under its patch, about 28 pt (guide page 16: 24–28).
    static let pageName = Font.system(.title, design: .serif, weight: .semibold)
    /// The count on the paper card, large.
    static let cardCount = Font.system(.title, design: .serif, weight: .semibold)
}
