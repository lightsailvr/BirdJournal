import Album
import Pack
import SwiftUI

/// The local set: the place's set with the birder's progress in it. The painting, "Your local set" and the app's tint all
/// follow the same choice (`CurrentPlace`, issue #150).
struct LocalSet {
    let set: PackSet
    let progress: SetProgress

    /// The set shown, with its progress; nil when the phone doesn't know it.
    @MainActor
    init?(setID: String?, library: PackLibrary, collection: CardCollection) {
        guard let set = library.sets.first(where: { $0.id == setID }) else { return nil }
        self.set = set
        progress = collection.progress(of: set.id)
    }

    /// The set whose regions contain the coordinate; else the set of the newest sighting, so outside every set it's your last
    /// one; else the bundled set; else the first the phone knows. Nil when it knows none.
    nonisolated static func choose(coordinate: Coordinate?, newestSetID: String?, sets: [CardSet], bundledID: String = PackIndex.bundledPackID) -> String? {
        if let coordinate, let here = CardSet.containing(coordinate, in: sets) { return here.id }
        if let newestSetID, sets.contains(where: { $0.id == newestSetID }) { return newestSetID }
        return sets.first { $0.id == bundledID }?.id ?? sets.first?.id
    }

    nonisolated static func choose(coordinate: Coordinate?, in collection: CardCollection) -> String? {
        choose(coordinate: coordinate, newestSetID: newestSetID(in: collection), sets: collection.sets)
    }

    /// The set of the newest sighting that's in one: an Uncharted one has none, and shouldn't lose your last set.
    nonisolated static func newestSetID(in collection: CardCollection) -> String? {
        collection.cards.lazy.compactMap { collection.placement(of: $0.identifier)?.setID }.first
    }
}

/// The calm ready state's atmosphere (page 11): the place's cover (issue #114) under the status bar, fading into the page, with
/// the wordmark and the headline over its sky. It follows the place (issue #150): a new painting cross-fades in, and under Reduce
/// Motion switches without the fade. The cover is illustrative, so it is labelled as an AI illustration and never stands for where
/// a bird was seen.
struct ListenCoverHeader: View {
    @Environment(CurrentPlace.self) private var place
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let local: LocalSet?
    /// The status bar's height, which the cover runs under.
    let topInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FEATHERGUILD")
                .font(.system(.caption, design: .serif, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.9))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityHidden(true)
            Text("Wonder is nearby.")
                .font(.system(.largeTitle, design: .serif, weight: .regular))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 120)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, JournalLayout.margin)
        .padding(.top, topInset + 18)
        .frame(minHeight: 300 + topInset, alignment: .top)
        .background {
            ZStack {
                // Fixed, like the paintings, for the white words: the five sets all have one, and this is for a set that doesn't.
                Color(hex: 0x10292D)
                    .overlay {
                        if let painting = place.painting {
                            Image(uiImage: painting)
                                .resizable()
                                .scaledToFill()
                                .allowsHitTesting(false)
                                .id(place.setID)
                                .transition(.opacity)
                        }
                    }
                    .clipped()
                    .animation(PatchMotion.reduces(system: systemReduceMotion) ? nil : .easeInOut(duration: 0.6), value: place.setID)
                // The sky darkens behind the headline, and the land fades into the page under it.
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
                LinearGradient(colors: [.clear, Color.paper], startPoint: UnitPoint(x: 0.5, y: 0.72), endPoint: .bottom)
            }
            .accessibilityElement()
            .accessibilityLabel("\(local?.set.name ?? "Featherguild") cover, AI illustration")
            .accessibilityIdentifier("listen-painting")
            .accessibilityHidden(place.painting == nil)
        }
        .overlay(alignment: .bottomTrailing) {
            if place.painting != nil {
                Text("AI illustration")
                    .font(CardFont.credit)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, JournalLayout.margin)
                    // Clear of the source row, which rises 36 points onto the cover (issue #119: it hid the credit).
                    .padding(.bottom, 42)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
    }
}

/// "Your local set" (the Listen mock's lower half): the set's name, which opens its page, and how many of its birds are sewn; the
/// thread; and the latest patches.
struct LocalSetSection: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var patchSide: CGFloat = 80
    let local: LocalSet
    let collection: CardCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name
                    Spacer(minLength: 8)
                    count
                }
                VStack(alignment: .leading, spacing: 2) {
                    name
                    count
                }
            }
            // Another place's thread is another thread: it doesn't sew from this one's count.
            ThreadProgress(local.progress)
                .id(local.set.id)
            let latest = latestPatches
            if latest.isEmpty {
                Text("Birds you add while listening are sewn as patches here, one for every bird in every place.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 14)
            } else {
                HStack(alignment: .center, spacing: 15) {
                    ForEach(latest) { patch in
                        LatestPatch(patch: patch, side: min(patchSide, typeSize.isAccessibilitySize ? 150 : 104))
                    }
                }
                .padding(.top, 14)
                .holdsPatchLight()
            }
        }
        .padding(.top, JournalLayout.sectionGap)
    }

    /// The set's name is the way to its page. It's the section's heading for VoiceOver, which also says whose set it is.
    private var name: some View {
        NavigationLink(value: Route.set(id: local.set.id)) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(local.set.name)
                    .font(JournalFont.heading)
                    .foregroundStyle(Color.ink)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.inkSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your local set, \(local.set.name)")
        .accessibilityHint("Opens the set")
        .accessibilityAddTraits(.isHeader)
    }

    /// The thread beside it reads this as a sentence.
    private var count: some View {
        Text(local.progress.sewnText)
            .font(JournalFont.supporting)
            .foregroundStyle(Color.ink)
            .accessibilityHidden(true)
    }

    /// The newest patches of the set, one per species: three, or two where they grow with the text.
    private var latestPatches: [CardCollection.Patch] {
        var seen = Set<String>()
        var patches: [CardCollection.Patch] = []
        for sighting in collection.cards where collection.placement(of: sighting.identifier)?.setID == local.set.id {
            guard seen.insert(sighting.scientificName).inserted, let patch = collection.patch(of: sighting.identifier) else { continue }
            patches.append(patch)
            if patches.count == (typeSize.isAccessibilitySize ? 2 : 3) { break }
        }
        return patches
    }
}

/// One of the latest patches, with no words under it, opening its page.
private struct LatestPatch: View {
    @Environment(PackLibrary.self) private var library
    let patch: CardCollection.Patch
    let side: CGFloat

    var body: some View {
        let state = library.patchArtState(scientificName: patch.scientificName, setID: patch.placement.setID)
        let name = PatchText.name(of: patch, library: library)
        let edition = PatchEdition.of(setID: patch.placement.setID)
        NavigationLink(value: Route.patch(patch.id, from: .latest)) {
            PatchView(state: state, edition: edition, tag: name)
                .frame(width: side)
                .patchLiftSource(PatchLiftID(key: patch.id, surface: .latest))
                // Its art takes no touches of its own (`PatchView`): the whole patch is what opens.
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PatchText.spoken(patch, name: name, beingSewn: state == .beingSewn))
        }
        .buttonStyle(.patchLift)
        .modifier(PatchPeekActions(patch: patch, surface: .latest, state: state, edition: edition, tag: name))
        .accessibilityHint("Opens the patch. Turn it over for its story.")
        .accessibilityIdentifier("board-patch")
    }
}
