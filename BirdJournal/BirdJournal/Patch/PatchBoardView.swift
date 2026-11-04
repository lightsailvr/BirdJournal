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

/// One set's felt board (issue #134, guide page 6): your patches in collector-number order, each with its count, then the
/// patterns of the birds still to find. A patch opens its page; a pattern, the bird's profile.
struct PatchBoard: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let set: PackSet
    /// Every place on the board, or the ones a search kept.
    let entries: [CardCollection.BoardEntry]

    var body: some View {
        FeltBoard {
            LazyVGrid(columns: PatchBoardLayout.grid(for: typeSize), spacing: 18) {
                ForEach(entries) { entry in
                    let name = set.species.first { $0.scientificName == entry.scientificName }?.commonName ?? entry.scientificName
                    if let patch = entry.patch {
                        SewnPatchTile(patch: patch, name: name)
                    } else {
                        NavigationLink(value: Route.species(scientificName: entry.scientificName, commonName: name)) {
                            PatchTile(
                                art: library.patchArt(scientificName: entry.scientificName, setID: set.id), edition: PatchEdition.of(setID: set.id), face: .pattern,
                                name: name, line: PatchText.patternLine(number: entry.number, total: entry.total),
                                spoken: PatchText.spokenPattern(name: name, number: entry.number, total: entry.total)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens its page in the Atlas.")
                        .accessibilityIdentifier("board-pattern")
                    }
                }
            }
        }
        .holdsPatchLight()
    }
}

/// The patches outside every set, on their own board.
struct UnchartedBoard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(PackLibrary.self) private var library
    let patches: [CardCollection.Patch]

    var body: some View {
        FeltBoard {
            LazyVGrid(columns: PatchBoardLayout.grid(for: typeSize), spacing: 18) {
                ForEach(patches) { patch in
                    SewnPatchTile(patch: patch, name: PatchText.name(of: patch, library: library))
                }
            }
        }
        .holdsPatchLight()
    }
}

/// A sewn patch on a board: it opens the patch's page.
struct SewnPatchTile: View {
    @Environment(PackLibrary.self) private var library
    let patch: CardCollection.Patch
    let name: String
    /// Under the name, in place of the number and count.
    var line: String? = nil
    /// The patch's sentence names the bird, even where the tile's words name the edition.
    var spokenName: String? = nil

    var body: some View {
        NavigationLink(value: Route.patch(patch.id)) {
            PatchTile(
                art: library.patchArt(scientificName: patch.scientificName, setID: patch.placement.setID), edition: PatchEdition.of(setID: patch.placement.setID), face: .sewn,
                name: name, line: line ?? PatchText.tileLine(patch), spoken: PatchText.spoken(patch, name: spokenName ?? name)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the patch. Turn it over for its story.")
        .accessibilityIdentifier("board-patch")
    }
}

/// A patch with its words under it, in type: the name, and the number and count. Under Increase Contrast the words sit on
/// a solid surface (guide page 14).
struct PatchTile: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let art: PatchArt?
    let edition: PatchEdition
    let face: PatchView.Face
    let name: String
    let line: String
    /// What VoiceOver reads: the tile is one element.
    let spoken: String

    var body: some View {
        VStack(spacing: 6) {
            PatchView(art: art, edition: edition, face: face)
                .frame(maxWidth: 124)
            VStack(spacing: 2) {
                Text(name)
                    .font(PatchFont.tileName)
                    .foregroundStyle(Color.ink)
                Text(line)
                    .font(PatchFont.tileLine)
                    .foregroundStyle(Color.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, contrast == .increased ? 6 : 0)
            .padding(.vertical, contrast == .increased ? 3 : 0)
            .background(contrast == .increased ? Color.paper : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
    /// The bird's name under its patch, about 28 pt (guide page 16: 24–28).
    static let pageName = Font.system(.title, design: .serif, weight: .semibold)
    /// The count on the paper card, large.
    static let cardCount = Font.system(.title, design: .serif, weight: .semibold)
}
