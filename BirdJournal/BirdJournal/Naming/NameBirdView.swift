import Album
import ImageIO
import Pack
import SwiftUI

/// "Name this bird" (issues #186 and #188, of #185): an unnamed sighting's photo with its time and place, and a search field
/// over bird names. The birds of the field-guide downloads on the phone come first, each with the set its patch would go in
/// and "New to you here" or "Seen 2 times here"; below them, every other bird BirdNET knows by name. Choosing one and
/// pressing the pinned "Add and sew patch" (or "Add sighting") writes the sighting, Seen, with the photo as its original
/// photo and the photo's own time and place, and closes; the phone then shows what any add does.
///
/// Before anything is typed the page suggests (issue #189): "Heard this run", the run's birds with those calling first,
/// when the photo is one of the run under way or under review; then "Likely here now", the field guides' birds the geomodel
/// finds most likely where the photo was taken, in the week it was taken. Typing replaces both with the search, and clearing
/// the field brings them back. `NameableBirds.search(_:in:)` decides all of it; this view draws what it returns.
///
/// The photo was saved at the shutter, so nothing here can lose it: "Name it later", a swipe down or the app being killed
/// all leave it an unnamed sighting, to be named from the run, its review or the Collection. Only "Delete photo", once
/// confirmed, removes it. The same sheet names a photo just taken and one that has waited for weeks, which is why where and
/// when come from the unnamed sighting and not from a run.
///
/// The same sheet is "Change bird" (issue #190), opened from the page of a sighting the birder named: the sighting's photo
/// and its bird now, the same suggestions and search read at the sighting's own place and week, the bird it is marked
/// among them, and a pinned "Change bird" (or "Change and sew patch") that can be pressed once another bird is chosen.
/// There is nothing to name later and no photo to delete, only Cancel; the change itself is the caller's.
struct NameBirdView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(PlaceNames.self) private var places
    @Environment(\.occurrenceModel) private var occurrenceModel
    /// The photo being named, or the sighting whose bird is being changed, with when and where it was taken.
    let subject: NamingSubject
    /// For a photo just chosen from the library (issue #192): whether the date and place above are the photo's own.
    let note: String?
    /// Writes a change of bird, and says whether it was written; nil while a photo is being named.
    private let change: ((NameableBird) -> Bool)?
    /// Closes the sheet: after the add or the change, on "Name it later" or Cancel, or after a delete.
    let close: () -> Void
    @State private var query = ""
    /// Nil while the label list is read.
    @State private var names: NameableBirds?
    /// What the photo's run had heard when the sheet opened, and what the geomodel expects at the photo's place in its week.
    @State private var context = NameableBirds.Context.none
    @State private var chosen: NameableBird?
    @State private var isAdding = false
    @State private var failed = false
    @State private var confirmingDelete = false
    @State private var deleteFailed = false
    @FocusState private var isSearching: Bool

    /// "Name this bird", for a photo waiting for its name.
    /// - Parameter note: one line under the photo, for one just chosen from the library (issue #192).
    init(unnamed: UnnamedSighting, note: String? = nil, close: @escaping () -> Void) {
        subject = .unnamed(unnamed)
        self.note = note
        change = nil
        self.close = close
    }

    /// "Change bird", for a sighting the birder named (issue #190).
    /// - Parameter change: writes the change to the bird chosen; false when it couldn't be written, and the sheet stays.
    init(changing sighting: NamedSighting, change: @escaping (NameableBird) -> Bool, close: @escaping () -> Void) {
        subject = .named(sighting)
        note = nil
        self.change = change
        self.close = close
    }

    /// The sightings of `bird` in the patch an add here would join; 0 when the add would sew a new patch.
    private func seenHere(_ bird: NameableBird) -> Int {
        collectionStore.collection.count(ofSpeciesID: bird.speciesID, at: subject.location)
    }

    /// The bird is the one the sighting being changed already is.
    private func isCurrent(_ bird: NameableBird) -> Bool {
        bird.scientificName == subject.changing?.scientificName
    }

    private func status(of bird: NameableBird) -> [String] {
        let placement = CardSet.placement(speciesID: bird.speciesID, at: subject.location, in: collectionStore.collection.sets)
        if isCurrent(bird) { return ChangeBirdText.currentStatus(placement: placement) }
        return NameBirdText.status(placement: placement, seenHere: seenHere(bird), isInFieldGuide: bird.isInFieldGuide)
    }

    /// Where the current bird's patch is, when the sighting being changed is its last: the change unpicks it.
    private func unpickedByChange(of sighting: NamedSighting) -> CardPlacement? {
        let collection = collectionStore.collection
        return collection.isLastSighting(of: sighting.id) ? collection.patch(of: sighting.id)?.placement : nil
    }

    var body: some View {
        let results = names?.search(query, in: context)
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    CapturedPhotoHeader(
                        bird: subject.changing?.commonName, photoPath: subject.photoPath, takenAt: subject.takenAt,
                        place: NameBirdText.place(location: subject.location, name: subject.location.flatMap(places.name(for:)))
                    )
                    .padding(.top, 8)
                    if let note {
                        hint(note)
                            .padding(.top, 10)
                            .accessibilityIdentifier("name-bird-photo-note")
                    }
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
            .navigationTitle(subject.changing == nil ? "Name this bird" : ChangeBirdText.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if subject.changing == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(UnnamedSightingText.later, action: close)
                            .accessibilityHint("Keeps the photo as an unnamed sighting")
                            .accessibilityIdentifier("name-bird-later")
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label(UnnamedSightingText.deleteAction, systemImage: "trash")
                        }
                        .accessibilityIdentifier("name-bird-delete")
                    }
                } else {
                    // A sighting is not a photo waiting: there is nothing to name later and nothing here deletes it.
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: close)
                            .accessibilityIdentifier("change-bird-cancel")
                    }
                }
            }
            // The one way a photo is lost, so it is asked twice; an alert, so keeping it is a button and not a tap elsewhere.
            .alert(UnnamedSightingText.deleteTitle, isPresented: $confirmingDelete) {
                Button(UnnamedSightingText.deleteAction, role: .destructive) { delete() }
                Button(UnnamedSightingText.keep, role: .cancel) {}
            } message: {
                Text(UnnamedSightingText.deleteMessage)
            }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) { addBar }
        }
        // The names and the suggestions arrive together, so the page opens on its suggestions and not on a list they replace.
        // Read again only if the photo's place changes under the sheet: with no run, a shutter quicker than the phone's
        // first fix gets its place a moment later (issue #191).
        .task(id: subject.location) {
            let known = names
            // What the run has heard is read once, as the sheet opens: the list holds still while a bird is chosen from it.
            let heard: [String] = if known != nil {
                context.heard
            } else {
                switch subject {
                case .unnamed(let unnamed): run.heardScientificNames(for: unnamed)
                case .named(let sighting): run.heardScientificNames(for: sighting)
                }
            }
            let fieldGuide = library.fieldGuideBirds, place = subject.location, takenAt = subject.takenAt, model = occurrenceModel
            let read = await Task.detached(priority: .userInitiated) {
                // Without the label list the field guides' birds can still be named.
                let names = known ?? (try? NameableBirds.load(fieldGuide: fieldGuide)) ?? NameableBirds(fieldGuide: fieldGuide, labels: [])
                return (names, NameableBirds.Context(heard: heard, place: place, takenAt: takenAt, occurrenceModel: model))
            }.value
            // The place changed while this was read: the read for the new place is on its way, and must not be overwritten.
            guard !Task.isCancelled else { return }
            (names, context) = read
            dropAChoiceOutOfSight()
        }
        .task(id: subject.location) {
            if let location = subject.location { await places.resolve(location) }
        }
        #if DEBUG
        .task {
            // `-autoQuery <text>` searches once, for the screenshots of the results and the no-match state.
            if let text = UserDefaults.standard.string(forKey: "autoQuery") { query = text }
        }
        #endif
        // A choice the page no longer shows would be added unseen.
        .onChange(of: query) { dropAChoiceOutOfSight() }
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
                    NameBirdRow(bird: bird, status: status(of: bird), isChosen: chosen == bird, isForASighting: subject.changing != nil) {
                        chosen = chosen == bird ? nil : bird
                        failed = false
                    }
                    RowRule()
                }
            }
            .padding(.top, 6)
        }
    }

    /// The add or the change, pinned above the keyboard and the home indicator.
    private var addBar: some View {
        let seen = chosen.map(seenHere)
        let changing = subject.changing
        // The bird the sighting already is can be looked at, not chosen as the change.
        let isUnchanged = chosen.map(isCurrent) ?? false
        return VStack(spacing: 8) {
            if failed {
                InlineError(changing == nil ? "The sighting couldn't be saved. Your photo is kept. Try again." : ChangeBirdText.failed, afterAction: true)
            } else if deleteFailed {
                InlineError("The photo couldn't be deleted. Try again.", afterAction: true)
            }
            Button {
                add()
            } label: {
                if changing == nil {
                    Label(isAdding ? "Adding…" : NameBirdText.addTitle(seenHere: seen), systemImage: "plus")
                } else {
                    Label(ChangeBirdText.confirmTitle(seenHere: isUnchanged ? nil : seen), systemImage: "checkmark")
                }
            }
            .buttonStyle(.journalPrimary)
            .disabled(chosen == nil || isAdding || isUnchanged)
            .accessibilityIdentifier(changing == nil ? "name-bird-add" : "change-bird-confirm")
            Text(changing.map { ChangeBirdText.note(current: $0.commonName, chosen: chosen?.commonName, isCurrent: isUnchanged, seenHere: seen ?? 0, unpicks: unpickedByChange(of: $0)) }
                ?? NameBirdText.addNote(name: chosen?.commonName, seenHere: seen ?? 0))
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
        deleteFailed = false
        let done = switch subject {
        case .unnamed(let unnamed): run.name(unnamed, as: chosen) != nil
        // No ceremony follows: the page under the sheet is the new bird's when the sheet closes.
        case .named: change?(chosen) ?? false
        }
        if done {
            close()
        } else {
            // The photo is still an unnamed sighting, or the sighting the bird it was: nothing closes on a failure.
            failed = true
        }
        isAdding = false
    }

    private func delete() {
        guard case .unnamed(let unnamed) = subject else { return }
        failed = false
        if run.delete(unnamed) {
            close()
        } else {
            deleteFailed = true
        }
    }
}

/// The photo being named, small, with when it was taken and where the sighting will be recorded. For a sighting whose bird
/// is being changed it leads with the bird the sighting is now, and has no picture once the birder has removed the photo.
private struct CapturedPhotoHeader: View {
    private static let maxPixels = 900

    @Environment(\.frameStore) private var frameStore
    /// The sighting's bird now; nil for a photo not yet named.
    let bird: String?
    let photoPath: String?
    let takenAt: Date
    let place: String
    @State private var image: UIImage?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 96
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let taken = NameBirdText.taken(takenAt)
        // At the largest sizes the words go under the picture: beside it they'd have a column a word wide.
        AdaptiveRow(stacked: typeSize.stacksRows) {
            if photoPath != nil {
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
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(bird ?? "Your photo")
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                if bird != nil, photoPath != nil { Text("Your photo") }
                Text(taken)
                Text(place)
            }
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NameBirdText.sentence([bird, photoPath == nil ? nil : (bird == nil ? "Your photo" : "your photo"), taken, place].compactMap { $0 }))
        .accessibilityAddTraits(photoPath == nil ? [] : .isImage)
        .accessibilityIdentifier("name-bird-photo")
        // Read from the album's own file, turned upright and no larger than the header needs: a camera's picture is far
        // larger than the slot.
        .task(id: photoPath) {
            guard let photoPath, let url = frameStore?.url(for: photoPath) else { return }
            let side = Self.maxPixels
            image = await Task.detached(priority: .userInitiated) { BirderPhoto.fitted(at: url, maxPixels: side) }.value
        }
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
    /// The choice is for a sighting whose bird is being changed, not for a photo being named.
    var isForASighting = false
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
        .accessibilityHint(isForASighting ? (isChosen ? "Chosen for this sighting" : "Chooses this bird for this sighting") : (isChosen ? "Chosen for your photo" : "Chooses this bird for your photo"))
        .accessibilityIdentifier("name-bird-\(bird.scientificName)")
    }
}
