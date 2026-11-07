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

    /// A patch's page opened from the tile `id`: it grows out of it and shrinks back to it, whichever patch a swipe has reached
    /// by then, since the tile opened is where the birder's eye left the board. Under the system's Reduce Motion the zoom itself
    /// is a cross-fade with nothing moving, seen frame by frame; `.crossFade` is for sheets, and on a push draws a slide. Opened
    /// some other way, or in a sheet's stack, a plain push.
    func patchLiftTransition(from id: PatchLiftID?) -> some View {
        modifier(PatchLiftTransition(id: id))
    }
}

/// Where a find's row is: the same find can be on the Guilds tab and on a Guild's page, both on one stack.
enum FindLiftSurface: Hashable, Sendable {
    case allGuilds
    case guild(String)
}

/// The patch on a find's row, which its page grows out of (issue #150, F1).
struct FindLiftID: Hashable, Sendable {
    let itemID: String
    let surface: FindLiftSurface
}

extension View {
    /// A find's patch, which its page grows out of.
    func findLiftSource(_ id: FindLiftID?) -> some View {
        modifier(FindLiftSource(id: id))
    }

    /// A find's page opened from the patch `id`. A quiet line has no patch to grow out of, so it's a plain push.
    func findLiftTransition(from id: FindLiftID?) -> some View {
        modifier(FindLiftTransition(id: id))
    }
}

private struct FindLiftSource: ViewModifier {
    @Environment(\.patchLiftNamespace) private var namespace
    let id: FindLiftID?

    func body(content: Content) -> some View {
        if let id, let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct FindLiftTransition: ViewModifier {
    @Environment(\.patchLiftNamespace) private var namespace
    let id: FindLiftID?

    func body(content: Content) -> some View {
        if let id, let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
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
