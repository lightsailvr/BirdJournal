import Album
import ImageIO
import Pack
import SwiftUI

/// "Name this bird" (issue #186, of #185): the photo just taken with its time and place, and a search field over bird
/// names. The birds of the field-guide downloads on the phone come first, each with the set its patch would go in and "New
/// to you here" or "Seen 2 times here"; below them, every other bird BirdNET knows by name. Choosing one and pressing the
/// pinned "Add and sew patch" (or "Add sighting") writes the sighting, Seen, with the photo as its original photo, and
/// closes; the run then shows what any add does.
///
/// Before anything is typed the page suggests (issue #189): "Heard this run", the run's birds with those calling first,
/// then "Likely here now", the field guides' birds the geomodel finds most likely at the run's place in the week of the
/// photo. Typing replaces both with the search, and clearing the field brings them back. `NameableBirds.search(_:in:)`
/// decides all of it; this view draws what it returns.
///
/// In this ticket Cancel discards the photo. #188 keeps it as an unnamed sighting instead and adds "Name it later"; #190
/// opens this sheet again to change a sighting's bird.
struct NameBirdView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(PlaceNames.self) private var places
    @Environment(\.occurrenceModel) private var occurrenceModel
    let photo: CapturedPhoto
    /// Closes the sheet: after the add, or on Cancel.
    let close: () -> Void
    @State private var query = ""
    /// Nil while the label list is read.
    @State private var names: NameableBirds?
    /// What the run had heard when the sheet opened, and what the geomodel expects at its place in the photo's week.
    @State private var context = NameableBirds.Context.none
    @State private var chosen: NameableBird?
    @State private var isAdding = false
    @State private var failed = false
    @FocusState private var isSearching: Bool

    /// The sightings of `bird` in the patch an add here would join; 0 when the add would sew a new patch.
    private func seenHere(_ bird: NameableBird) -> Int {
        collectionStore.collection.count(ofSpeciesID: bird.speciesID, at: run.coordinate)
    }

    private func status(of bird: NameableBird) -> [String] {
        NameBirdText.status(
            placement: CardSet.placement(speciesID: bird.speciesID, at: run.coordinate, in: collectionStore.collection.sets),
            seenHere: seenHere(bird), isInFieldGuide: bird.isInFieldGuide
        )
    }

    var body: some View {
        let results = names?.search(query, in: context)
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    CapturedPhotoHeader(photo: photo, place: NameBirdText.place(location: run.coordinate, name: run.coordinate.flatMap(places.name(for:))))
                        .padding(.top, 8)
                    searchField
                        .padding(.top, 16)
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        // Before anything is typed the page suggests, from the run and the field guides: the rest are found by name.
                        hint(NameBirdText.searchHint)
                            .padding(.top, 8)
                    }
                    if let results {
                        if results.isEmpty {
                            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                                NoSearchMatch(query: query) { query = "" }
                                    .padding(.top, 12)
                            }
                        } else {
                            section(NameBirdText.heardTitle, birds: results.heard)
                            section(NameBirdText.likelyTitle, birds: results.likely)
                            section("In your field guides", birds: results.fieldGuide)
                            section("All birds", birds: results.others)
                            if let more = NameBirdText.more(results.moreOthers) {
                                hint(more)
                                    .padding(.top, 12)
                            }
                        }
                    } else {
                        ProgressView("Reading the bird names")
                            .font(JournalFont.supporting)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                }
            }
            .navigationTitle("Name this bird")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                        .accessibilityHint("Discards the photo")
                }
            }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) { addBar }
        }
        // The names and the suggestions arrive together, so the page opens on its suggestions and not on a list they replace.
        // A place that arrives later reads the geomodel again.
        .task(id: run.coordinate) {
            // What the run has heard is read once, as the sheet opens: the list holds still while a bird is chosen from it.
            let heard = names == nil ? run.heardScientificNames : context.heard
            let known = names, fieldGuide = library.fieldGuideBirds, place = run.coordinate, takenAt = photo.takenAt, model = occurrenceModel
            let loaded = await Task.detached(priority: .userInitiated) {
                // Without the label list the field guides' birds can still be named.
                let names = known ?? (try? NameableBirds.load(fieldGuide: fieldGuide)) ?? NameableBirds(fieldGuide: fieldGuide, labels: [])
                return (names, NameableBirds.Context(heard: heard, place: place, takenAt: takenAt, occurrenceModel: model))
            }.value
            guard !Task.isCancelled else { return }
            (names, context) = loaded
        }
        .task(id: run.coordinate) {
            if let coordinate = run.coordinate { await places.resolve(coordinate) }
        }
        #if DEBUG
        .task {
            // `-autoQuery <text>` searches once, for the screenshots of the results and the no-match state.
            if let text = UserDefaults.standard.string(forKey: "autoQuery") { query = text }
        }
        #endif
        // A choice the page no longer shows would be added unseen.
        .onChange(of: query) { dropAChoiceOutOfSight() }
        .onChange(of: context) { dropAChoiceOutOfSight() }
    }

    private func dropAChoiceOutOfSight() {
        if let chosen, let results = names?.search(query, in: context), !results.birds.contains(chosen) { self.chosen = nil }
    }

    /// The search, under the photo and on the page: the bar keeps the sheet's title and its Cancel while a name is typed,
    /// which the system's search field would take over.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.inkSecondary)
                .accessibilityHidden(true)
            TextField("Search birds by name", text: $query)
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearching)
                .accessibilityIdentifier("name-bird-search")
            if !query.isEmpty {
                Button {
                    query = ""
                    isSearching = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.inkSecondary)
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(_ title: String, birds: [NameableBird]) -> some View {
        if !birds.isEmpty {
            SectionTitle(title, top: 22)
            LazyVStack(spacing: 0) {
                ForEach(birds) { bird in
                    NameBirdRow(bird: bird, status: status(of: bird), isChosen: chosen == bird) {
                        chosen = chosen == bird ? nil : bird
                        failed = false
                    }
                    RowRule()
                }
            }
            .padding(.top, 6)
        }
    }

    /// The add, pinned above the keyboard and the home indicator.
    private var addBar: some View {
        let seen = chosen.map(seenHere)
        return VStack(spacing: 8) {
            if failed {
                InlineError("The sighting couldn't be saved. Try again.", afterAction: true)
            }
            Button {
                add()
            } label: {
                Label(isAdding ? "Adding…" : NameBirdText.addTitle(seenHere: seen), systemImage: "plus")
            }
            .buttonStyle(.journalPrimary)
            .disabled(chosen == nil || isAdding)
            .accessibilityIdentifier("name-bird-add")
            Text(NameBirdText.addNote(name: chosen?.commonName, seenHere: seen ?? 0))
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Pinned over the list: past this size it would leave no room for the birds it is choosing among.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, JournalLayout.margin)
        .padding(.vertical, 12)
    }

    private func add() {
        guard let chosen, !isAdding else { return }
        isAdding = true
        if run.addSeen(chosen, photo: photo) != nil {
            close()
        } else {
            // The photo is still here: nothing closes on a failure.
            failed = true
        }
        isAdding = false
    }
}

/// The photo being named, small, with when it was taken and where the sighting will be recorded.
private struct CapturedPhotoHeader: View {
    private static let maxPixels = 900

    let photo: CapturedPhoto
    let place: String
    @State private var image: UIImage?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 96
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let taken = NameBirdText.taken(photo.takenAt)
        // At the largest sizes the words go under the picture: beside it they'd have a column a word wide.
        AdaptiveRow(stacked: typeSize.stacksRows) {
            Color.raised
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .allowsHitTesting(false)  // DECISIONS.md "Clipped images take no touches"
                    }
                }
                .clipped()
                .frame(width: min(side, 140), height: min(side, 140))
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your photo")
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                Text(taken)
                Text(place)
            }
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your photo, \(taken), \(place)")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("name-bird-photo")
        .task(id: photo.id) {
            let data = photo.data
            image = await Task.detached(priority: .userInitiated) { Self.fitted(data) }.value
        }
    }

    /// The photo turned upright and no larger than the header needs: a camera's picture is far larger than the slot.
    nonisolated private static func fitted(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}

/// One bird among the results: its reference photo when a field guide has one, its names, where its patch would go, and a
/// check once it is the one chosen.
private struct NameBirdRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    let bird: NameableBird
    let status: [String]
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                if bird.isInFieldGuide, !typeSize.stacksRows {
                    PackImage(url: library.thumbnailURL(scientificName: bird.scientificName))
                        .rowPicture(48)
                        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(bird.commonName)
                        .font(JournalFont.rowTitle)
                        .foregroundStyle(Color.ink)
                    Text(bird.scientificName)
                        .font(JournalFont.scientific)
                        .foregroundStyle(Color.inkSecondary)
                    Text(NameBirdText.line(status))
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.rule))
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // One sentence for the row; the button around it keeps its action.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NameBirdText.spoken(name: bird.commonName, status: status))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityHint(isChosen ? "Chosen for your photo" : "Chooses this bird for your photo")
        .accessibilityIdentifier("name-bird-\(bird.scientificName)")
    }
}
