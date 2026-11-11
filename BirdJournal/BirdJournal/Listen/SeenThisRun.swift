import Album
import Pack
import SwiftUI

/// "Seen this run" (issues #186 and #188, of #185), above the birds heard on the run's page and in the run's review: a row for
/// each photo the birder took on this run, in the order taken. One that has its name shows the bird, "Seen · your photo · New
/// patch" or its patch's count, and opens its sighting; no match score, since the birder named it. One still waiting is an
/// "Unnamed sighting" with "Name it", which opens "Name this bird" for it. Naming a row leaves it where it was.
struct SeenThisRun: View {
    let seen: [RunSightings.Seen]
    /// The photos of this run not yet named.
    var unnamed: [UnnamedSighting] = []
    /// A line under the rows: the review says what becomes of the photos still unnamed.
    var footnote: String? = nil
    @State private var naming: UnnamedSighting?

    /// One photo of the run, named or not.
    enum Row: Identifiable, Equatable {
        case seen(RunSightings.Seen)
        case unnamed(UnnamedSighting)

        var id: String {
            switch self {
            case .seen(let entry): "seen-\(entry.identifier)"
            case .unnamed(let unnamed): "unnamed-\(unnamed.id)"
            }
        }

        var takenAt: Date {
            switch self {
            case .seen(let entry): entry.seenAt
            case .unnamed(let unnamed): unnamed.takenAt
            }
        }
    }

    /// The run's photos in the order taken, whether or not each has its name yet; two of one moment, named first.
    static func rows(seen: [RunSightings.Seen], unnamed: [UnnamedSighting]) -> [Row] {
        let all = seen.map(Row.seen) + unnamed.map(Row.unnamed)
        return all.enumerated().sorted { ($0.element.takenAt, $0.offset) < ($1.element.takenAt, $1.offset) }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Seen this run", top: 22)
            VStack(spacing: 0) {
                ForEach(Self.rows(seen: seen, unnamed: unnamed)) { row in
                    switch row {
                    case .seen(let entry): SeenRow(entry: entry)
                    case .unnamed(let unnamed): UnnamedSightingRow(unnamed: unnamed) { naming = unnamed }
                    }
                    RowRule()
                }
            }
            .padding(.top, 6)
            if let footnote, !unnamed.isEmpty {
                Text(footnote)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("seen-this-run")
        .namesUnnamedSighting($naming)
    }
}

private struct SeenRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: RunSightings.Seen

    var body: some View {
        let collection = collectionStore.collection
        let name = library.species(scientificName: entry.scientificName)?.species.commonName ?? entry.commonName
        let parts = NameBirdText.seenRow(sewedPatch: collection.sewedItsPatch(entry.identifier), count: collection.patch(of: entry.identifier)?.count ?? 1)
        NavigationLink(value: Route.sighting(entry.id)) {
            AdaptiveRow(stacked: typeSize.stacksRows) {
                BirderPhoto(path: entry.photoPath, isGlassesFrame: entry.photoIsGlassesFrame)
                    .rowPicture()
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(JournalFont.rowTitle)
                        .foregroundStyle(Color.ink)
                    Text(NameBirdText.line(parts))
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NameBirdText.sentence([name] + parts))
            .accessibilityHint("Opens the sighting")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("seen-row-\(entry.scientificName)")
    }
}
