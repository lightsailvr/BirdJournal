import Album
import SwiftData
import SwiftUI

/// Which kind of tile a patch was opened from. The same patch can have a tile on several pages of one stack (the board, and a
/// species' patches pushed on top of it), and a zoom has to know which it came from.
enum PatchLiftSurface: Hashable, Sendable {
    case board, latest, species
}

/// The tile a patch's page grows out of, and shrinks back to.
struct PatchLiftID: Hashable, Sendable {
    let key: CardCollection.Patch.Key
    let surface: PatchLiftSurface
}

extension EnvironmentValues {
    /// The namespace a tab's patch tiles and their pages share. Routes reach the page, so it comes through here.
    @Entry var patchLiftNamespace: Namespace.ID?
    /// Puts a route on the stack this view is in, for what a `NavigationLink` can't do: a context menu's item.
    @Entry var pushRoute: @MainActor (Route) -> Void = { _ in }
}

extension View {
    /// Gives a navigation stack what its patch tiles need: its own namespace, since the same tile id on two stacks mustn't compete,
    /// and the way to put a route on it. Every stack that can reach a tile needs this, sheets included, or a tile's peek would push
    /// onto the stack behind the sheet.
    /// - Parameter lifts: false in a sheet, where a zoom cuts straight to the page and shows the page behind the sheet for a few
    ///   frames (seen on the map's sheet): there it's a plain push, on purpose.
    func patchStack(lifts: Bool = true, push: @escaping @MainActor (Route) -> Void) -> some View {
        modifier(PatchLiftScope(lifts: lifts)).environment(\.pushRoute, push)
    }

    /// The tile `id`'s picture, which its page grows out of.
    func patchLiftSource(_ id: PatchLiftID?) -> some View {
        modifier(PatchLiftSource(id: id))
    }

    /// For a scroll view with patch tiles, under a stack whose pages hide the tab bar. The page makes it taller, and at its foot that
    /// would pull the offset back by the bar's height, so the page would land short of its tile. Room below the content for as long
    /// as that lasts keeps the offset where it was, and nothing has to be put back. It's never seen: the page covers it.
    func keepsItsFootUnderAPage(isCovered: Bool) -> some View {
        modifier(CoverRoom(isCovered: isCovered))
    }

    /// A patch's page opened from the tile `id`: it grows out of it and shrinks back to it, whichever patch a swipe has reached
    /// by then, since the tile opened is where the birder's eye left the board. Under the system's Reduce Motion the zoom itself
    /// is a cross-fade with nothing moving, seen frame by frame; `.crossFade` is for sheets, and on a push draws a slide. Opened
    /// some other way, or in a sheet's stack, a plain push.
    func patchLiftTransition(from id: PatchLiftID?) -> some View {
        modifier(PatchLiftTransition(id: id))
    }
}

private struct PatchLiftScope: ViewModifier {
    @Namespace private var namespace
    let lifts: Bool

    func body(content: Content) -> some View {
        content.environment(\.patchLiftNamespace, lifts ? namespace : nil)
    }
}

private struct PatchLiftSource: ViewModifier {
    @Environment(\.patchLiftNamespace) private var namespace
    let id: PatchLiftID?

    func body(content: Content) -> some View {
        if let id, let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct CoverRoom: ViewModifier {
    let isCovered: Bool
    @State private var isThere = false
    @State private var going: Task<Void, Never>?
    /// More than any tab bar.
    private static let room: CGFloat = 140
    /// How long the room stays after the way back. `-coverRoomSeconds <n>` holds it, for a test to flick into it.
    private static var seconds: Double {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "coverRoomSeconds")
        if seconds > 0 { return seconds }
        #endif
        return 1.5
    }

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, isThere ? Self.room : 0, for: .scrollContent)
            .onChange(of: isCovered) { _, covered in
                going?.cancel()
                if covered {
                    isThere = true
                } else {
                    // Once the tab bar is surely back, when the room can go without anything moving.
                    going = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.seconds))
                        if !Task.isCancelled { isThere = false }
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                // The bar's back by the time a finger can be on the board, and a flick mustn't reach empty felt, then be pulled back
                // when the room goes.
                if phase == .interacting, !isCovered {
                    going?.cancel()
                    isThere = false
                }
            }
    }
}

private struct PatchLiftTransition: ViewModifier {
    @Environment(\.patchLiftNamespace) private var namespace
    let id: PatchLiftID?

    func body(content: Content) -> some View {
        if let id, let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// A long press on a patch tile: a peek at the patch, with Turn over, Share and its sightings. Every tile has it.
struct PatchPeekActions: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.pushRoute) private var pushRoute
    let patch: CardCollection.Patch
    let surface: PatchLiftSurface
    let state: PatchArtState
    let edition: PatchEdition
    let tag: String
    @State private var sharing: Sighting?

    /// The newest sighting: what the patch page's Share shares. Fetched when asked for: a board of tiles shouldn't each hold the album.
    private var newestSighting: Sighting? {
        guard let identifier = patch.sightings.first?.identifier else { return nil }
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    pushRoute(.patch(patch.id, from: surface, turned: true))
                } label: {
                    Label("Turn over", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                Button {
                    sharing = newestSighting
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    pushRoute(.sightings(.patch(patch.id)))
                } label: {
                    Label(PatchText.allSightings(patch.count), systemImage: "list.bullet")
                }
            } preview: {
                PatchPeek(state: state, edition: edition, tag: tag)
            }
            .sheet(item: $sharing) { sighting in
                ShareCardView(sighting: sighting)
            }
    }
}

/// What a long press on a patch tile peeks at: the patch, large, on its felt.
struct PatchPeek: View {
    let state: PatchArtState
    let edition: PatchEdition
    let tag: String

    var body: some View {
        PatchView(state: state, edition: edition, size: .full, tag: tag)
            .frame(width: 280)
            .padding(28)
            .background { BoardMaterial() }
    }
}
