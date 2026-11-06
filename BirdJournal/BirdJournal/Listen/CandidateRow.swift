import Album
import Identification
import Pack
import SwiftUI

/// One species heard (issue #150, V2, L1, L2), in one of three looks. A bird an add would sew shows its reference photo in a
/// dashed transfer-pen ring, with "new here" in the tint and Sew it. One you have shows your patch and its count, with Add. One
/// added on this run shows the patch and a check. Sew it and Add call the same add as the review sheet, with the same reveal,
/// count and Undo; the rest of the row opens the review. A bird no installed pack describes keeps Review: nothing is added with
/// nothing to compare it against. A calling bird has the level glyph, "Calling now" and an outline on its patch, and its row is
/// raised by the list; rows never move when the scores change, only with the list order (issue #42).
struct CandidateRow: View {
    @Environment(PackLibrary.self) private var library
    @Environment(ListeningCoordinator.self) private var run
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let candidate: Candidate
    var isCalling = false
    /// The moment the heard text is written against, from the screen's clock.
    var now: Date = .now
    /// The row's position in the list, for the UI tests.
    var position: Int?
    let review: () -> Void
    /// VoiceOver's focus has come to this row or left it. The list holds still around it, so that focus keeps its place.
    var voiceOverFocused: (Bool) -> Void = { _ in }
    @AccessibilityFocusState private var focus: RowElement?
    /// An add from this row is under way (a glasses run takes a photo first): a second tap isn't a second sighting.
    @State private var isAdding = false

    var body: some View {
        let reference = library.species(scientificName: candidate.species.scientificName)
        let name = reference?.species.commonName ?? candidate.species.commonName
        let patch = collectionStore.collection.patch(forSpeciesID: candidate.species.birdnetLabel, at: run.coordinate)
        let look = CandidateLook(seenHere: patch?.count ?? 0, isAdded: run.isAdded(candidate))
        let heard = Self.heardText(candidate, startedAt: run.startedAt, now: now)
        let stacked = typeSize.stacksRows
        AdaptiveRow(stacked: stacked, spacing: 0) {
            Button(action: review) {
                AdaptiveRow(stacked: stacked) {
                    picture(look: look, patch: patch)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(JournalFont.rowTitle)
                            .foregroundStyle(Color.ink)
                        statusLine(look: look, heard: heard)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 12)
                .padding(.trailing, stacked ? 0 : 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(look.spoken(name: name, heard: heard, isCalling: isCalling))
                .accessibilityHint("Opens the review")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(position.map { "candidate-row-\($0)" } ?? "")
            .accessibilityFocused($focus, equals: .row)
            action(look.offer(isDescribed: reference != nil), name: name, isDescribed: reference != nil)
                .accessibilityFocused($focus, equals: .action)
                .padding(.bottom, stacked ? 12 : 0)
        }
        .onChange(of: focus != nil) { _, isFocused in voiceOverFocused(isFocused) }
        #if DEBUG
        .onAppear { Self.appearances += 1 }
        #endif
    }

    #if DEBUG
    /// Rows made since the test last set this to 0: a re-sort moves rows and makes none (`ScreenAccessibilityTests`).
    static var appearances = 0
    #endif

    private enum RowElement: Hashable {
        case row, action
    }

    /// Your patch once you have it here, else the reference photo in a ring that says it isn't yours yet.
    @ViewBuilder
    private func picture(look: CandidateLook, patch: CardCollection.Patch?) -> some View {
        if let patch, look != .newHere {
            RowPatch(scientificName: patch.scientificName, setID: patch.placement.setID, isCalling: isCalling)
                .rowPicture()
        } else {
            PackImage(url: library.thumbnailURL(scientificName: candidate.species.scientificName))
                .rowPicture()
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .overlay {
                    // The `TransferPen` colorset: what's marked out on the cloth and not sewn yet.
                    RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius + 3, style: .continuous)
                        .strokeBorder(Color.transferPen, style: StrokeStyle(lineWidth: 2, dash: [5, 3.5]))
                        .padding(-3.5)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// "Calling now, new here", "3 min ago, seen 7 times" or "Added, seen 8 times": what's new and what's calling in the tint.
    private func statusLine(look: CandidateLook, heard: String) -> some View {
        let isNew = look == .newHere
        return ZStack(alignment: .topLeading) {
            // Room for the line this row says when its bird calls, so that a row doesn't change height, and move the ones below it,
            // when a bird starts calling or stops. The list holds its order around a touch; this holds its rows' places.
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                Text("Calling now, \(look.note)")
                    .font(JournalFont.supporting.weight(.semibold))
            }
            .hidden()
            .accessibilityHidden(true)
            statusWords(look: look, heard: heard, isNew: isNew)
        }
    }

    private func statusWords(look: CandidateLook, heard: String, isNew: Bool) -> some View {
        HStack(spacing: 5) {
            if isCalling {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Group {
                if case .added = look, !isCalling {
                    Text(look.note.capitalizedFirst).foregroundStyle(Color.inkSecondary)
                } else {
                    let when = isCalling ? Text("Calling now").foregroundStyle(.tint).fontWeight(.semibold) : Text(heard.capitalizedFirst).foregroundStyle(Color.inkSecondary)
                    let note = Text(", \(look.note)")
                    Text("\(when)\(isNew ? note.foregroundStyle(.tint).fontWeight(.semibold) : note.foregroundStyle(Color.inkSecondary))")
                }
            }
            .font(JournalFont.supporting)
        }
    }

    @ViewBuilder
    private func action(_ offer: CandidateLook.Offer, name: String, isDescribed: Bool) -> some View {
        switch offer {
        case .sewIt:
            Button("Sew it") { add(isDescribed: isDescribed) }
                .buttonStyle(.journalRowPill(isFilled: true))
                .disabled(isAdding)
                .accessibilityLabel("Sew it, \(name)")
                .accessibilityHint("Adds it as Heard. You can change that on its sighting.")
        case .add:
            Button("Add") { add(isDescribed: isDescribed) }
                .buttonStyle(.journalRowPill(isFilled: false))
                .disabled(isAdding)
                .accessibilityLabel("Add \(name)")
                .accessibilityHint("Adds it as Heard. You can change that on its sighting.")
        case .review:
            Button("Review", action: review)
                .buttonStyle(.journalRowPill(isFilled: false))
                .accessibilityLabel("Review \(name)")
        case .added:
            Button(action: review) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Added. Review \(name)")
        }
    }

    private func add(isDescribed: Bool) {
        isAdding = true
        Task {
            await run.addFromRow(candidate, isDescribed: isDescribed)
            isAdding = false
        }
    }

    /// "just now" within the last minute, else minutes ago, from the run's own clock.
    static func heardText(_ candidate: Candidate, startedAt: Date?, now: Date) -> String {
        guard let startedAt else { return "just now" }
        return AgeText.text(seconds: now.timeIntervalSince(startedAt) - candidate.lastHeardAt)
    }
}

/// The run's line: "1 new patch waiting" in the tint, then what you already have.
struct HuntSummary: View {
    let hunt: RunHunt
    /// The run's page centres it, as it does the line under its rows; a page of left-aligned lines doesn't.
    var isCentred = true

    var body: some View {
        Group {
            if let waiting = hunt.waiting {
                Text("\(Text(waiting).foregroundStyle(.tint).fontWeight(.semibold))\(hunt.rest)")
            } else {
                Text(hunt.rest)
            }
        }
        .font(JournalFont.body)
        .foregroundStyle(Color.inkSecondary)
        .multilineTextAlignment(isCentred ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: isCentred ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
}
