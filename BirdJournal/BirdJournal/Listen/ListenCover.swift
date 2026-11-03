import Album
import Pack
import SwiftData
import SwiftUI

/// The local set the Listen tab invites the birder to (issue #117, design guide page 11): the set of their newest card,
/// else the bundled pack's, else the first set the phone knows. Nil when the phone knows no set.
struct LocalSet {
    let set: PackSet
    let progress: SetProgress

    @MainActor
    static func find(library: PackLibrary, collection: CardCollection, newest: Sighting?) -> LocalSet? {
        let sets = library.sets
        let preferred = newest.flatMap { collection.placement(of: $0.identifier)?.setID }
        guard let set = sets.first(where: { $0.id == preferred })
            ?? sets.first(where: { $0.id == PackIndex.bundledPackID })
            ?? sets.first
        else { return nil }
        return LocalSet(set: set, progress: collection.progress(of: set.id))
    }

    /// "Los Angeles · Citrus edition".
    var title: String { "\(set.name) · \(set.edition.name)" }
    /// "18 of 160 species collected".
    var progressText: String { "\(progress.collected) of \(progress.total) species collected" }
}

/// The calm ready state's atmosphere (page 11): the local set's cover (issue #114) under the status bar, fading into the
/// page, with the wordmark and the headline over its sky. Without a cover, the edition's designed fallback. The cover
/// is illustrative, so it is labelled as an AI illustration and never stands for where a bird was seen.
struct ListenCoverHeader: View {
    @Environment(PackLibrary.self) private var library
    let local: LocalSet?
    /// The status bar's height, which the cover runs under.
    let topInset: CGFloat

    var body: some View {
        let cover = local.flatMap { library.cover(setID: $0.set.id) }
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
                if let cover {
                    SetCoverArt(cover: cover)
                } else {
                    EditionFallback(edition: local?.set.edition.name)
                }
                // The sky darkens behind the headline, and the land fades into the page under it.
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
                LinearGradient(colors: [.clear, Color.paper], startPoint: UnitPoint(x: 0.5, y: 0.72), endPoint: .bottom)
            }
            .accessibilityElement()
            .accessibilityLabel(cover == nil ? "\(local?.set.edition.name ?? "Featherguild") pattern" : "\(local?.set.name ?? "Set") cover, AI illustration")
        }
        .overlay(alignment: .bottomTrailing) {
            if cover != nil {
                Text("AI illustration")
                    .font(CardFont.credit)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, JournalLayout.margin)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
    }
}

/// A set's cover, cropped from the middle to fill: the pack's full cover, or the index's thumbnail before the pack is on
/// the phone. It decodes through the Atlas's `SetCoverImage.load`; the fallback differs from the Atlas's, so it is
/// drawn by the header.
private struct SetCoverArt: View {
    let cover: SetCover
    @State private var image: UIImage?

    var body: some View {
        Color.raised
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .task(id: cover) {
                image = await SetCoverImage.load(cover)
            }
    }
}

/// The designed fallback for a set without a cover (#114's follow-up): a dusk wash in the set's edition, a low horizon
/// and the perched bird, quiet enough to sit behind the headline in either appearance. Its colours are fixed, like the
/// cover paintings.
private struct EditionFallback: View {
    let edition: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.063, green: 0.161, blue: 0.176), Color(red: 0.184, green: 0.373, blue: 0.361), Color(red: 0.827, green: 0.706, blue: 0.459).opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            Ellipse()
                .fill(Color(red: 0.098, green: 0.227, blue: 0.239))
                .frame(height: 140)
                .scaleEffect(x: 1.6)
                .offset(y: 70)
            PerchedBirdDrawing()
                .frame(height: 90)
                .opacity(0.5)
                .padding(.bottom, 54)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 36)
        }
    }
}

/// "Your local set" (page 11's local-set invitation): the set and its edition, how many of its species the birder has
/// collected (distinct species, page 12), and the way to the set's page.
struct LocalSetSection: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let local: LocalSet
    let collection: CardCollection
    let sightings: [Sighting]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    heading
                    Spacer(minLength: 8)
                    explore
                }
                VStack(alignment: .leading, spacing: 6) {
                    heading
                    explore
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(local.title)
                        Spacer(minLength: 8)
                        Text(local.progressText)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(local.title)
                        Text(local.progressText)
                    }
                }
                .font(JournalFont.supporting)
                .foregroundStyle(Color.ink)
                ProgressView(value: Double(local.progress.collected), total: Double(max(local.progress.total, 1)))
                    .tint(Color.moss)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(local.title), \(local.progressText)")
            let latest = latestCards
            if !latest.isEmpty {
                let columns = Array(repeating: GridItem(.flexible(), spacing: JournalLayout.rowGap, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2)
                LazyVGrid(columns: columns, spacing: JournalLayout.rowGap) {
                    ForEach(latest) { sighting in
                        NavigationLink(value: Route.card(sighting.persistentModelID)) {
                            CardTile(sighting: sighting, isLegendary: collection.isLegendary(sighting.identifier), placement: collection.placement(of: sighting.identifier))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Birds you add while listening become cards here, one for every sighting.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .padding(.top, JournalLayout.sectionGap)
    }

    private var heading: some View {
        Text("Your local set")
            .font(JournalFont.section)
            .foregroundStyle(Color.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var explore: some View {
        NavigationLink(value: Route.set(id: local.set.id)) {
            HStack(spacing: 4) {
                Text("Explore the set")
                Image(systemName: "arrow.right")
                    .accessibilityHidden(true)
            }
            .font(JournalFont.supporting.weight(.semibold))
            .foregroundStyle(Color.moss)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Explore the \(local.set.name) set")
    }

    /// The newest cards of the set's species, one per species, at most two.
    private var latestCards: [Sighting] {
        var seen = Set<String>()
        var cards: [Sighting] = []
        for sighting in sightings where collection.placement(of: sighting.identifier)?.setID == local.set.id {
            guard seen.insert(sighting.scientificName).inserted else { continue }
            cards.append(sighting)
            if cards.count == (typeSize.isAccessibilitySize ? 1 : 2) { break }
        }
        return cards
    }
}
