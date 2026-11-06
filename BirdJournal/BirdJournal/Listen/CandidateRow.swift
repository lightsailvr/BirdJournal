import Album
import Identification
import Pack
import SwiftUI

/// One species heard (issue #150, V2, L1, L2), in one of three looks. A bird an add would sew shows its reference photo in a
/// dashed transfer-pen ring, with "new here" in the tint and Sew it. One you have shows your patch and its count, with Add. One
/// added on this run shows the patch and a check. Sew it and Add call the same add as the review sheet, with the same reveal,
/// count and Undo; the rest of the row opens the review. A bird no installed pack describes keeps Review: nothing is added with
/// nothing to compare it against. A calling bird has the level glyph and "Calling now", and its row is raised by the list;
/// rows never move when the scores change, only with the list order (issue #42).
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
    /// An add from this row is under way (a glasses run takes a photo first): a second tap isn't a second sighting.
    @State private var isAdding = false

    var body: some View {
        let reference = library.species(scientificName: candidate.species.scientificName)
        let name = reference?.species.commonName ?? candidate.species.commonName
        let patch = collectionStore.collection.patch(forSpeciesID: candidate.species.birdnetLabel, at: run.coordinate)
        let look = CandidateLook(seenHere: patch?.count ?? 0, isAdded: run.isAdded(candidate))
        let heard = Self.heardText(candidate, startedAt: run.startedAt, now: now)
        let stacked = typeSize.stacksRows
        AdaptiveRow(stacked: stacked) {
            Button(action: review) {
                AdaptiveRow(stacked: stacked) {
                    picture(look: look, patch: patch, reference: reference)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(JournalFont.heading)
                            .foregroundStyle(Color.ink)
                        statusLine(look: look, heard: heard)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(look.spoken(name: name, heard: heard, isCalling: isCalling))
                .accessibilityHint("Opens the review")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(position.map { "candidate-row-\($0)" } ?? "")
            action(look.offer(isDescribed: reference != nil), name: name, isDescribed: reference != nil)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: review)
    }

    /// Your patch once you have it here, else the reference photo in a ring that says it isn't yours yet.
    @ViewBuilder
    private func picture(look: CandidateLook, patch: CardCollection.Patch?, reference: (pack: SpeciesPack, species: PackSpecies)?) -> some View {
        if let patch, look != .newHere {
            RowPatch(scientificName: patch.scientificName, setID: patch.placement.setID)
                .rowPicture()
        } else {
            PackImage(url: reference.flatMap { found in found.species.photos.first.map(found.pack.lensImageURL(for:)) })
                .rowPicture()
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius + 3, style: .continuous)
                        // The `TransferPen` colorset: what's marked out on the cloth and not sewn yet. Never words.
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
        return HStack(spacing: 5) {
            if isCalling {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Group {
                if case .added = look {
                    Text(look.note).foregroundStyle(Color.inkSecondary)
                } else {
                    let when = isCalling ? Text("Calling now").foregroundStyle(.tint) : Text(heard.capitalizedFirst).foregroundStyle(Color.inkSecondary)
                    let note = Text(", \(look.note)")
                    Text("\(when)\(isNew ? note.foregroundStyle(.tint) : note.foregroundStyle(Color.inkSecondary))")
                }
            }
            .font(JournalFont.supporting.weight(isNew || isCalling ? .medium : .regular))
        }
    }

    @ViewBuilder
    private func action(_ offer: CandidateLook.Offer, name: String, isDescribed: Bool) -> some View {
        switch offer {
        case .sewIt:
            Button("Sew it") { add(isDescribed: isDescribed) }
                .buttonStyle(RowPillStyle(isFilled: true))
                .disabled(isAdding)
                .accessibilityLabel("Sew it, \(name)")
                .accessibilityHint("Adds it as Heard. You can change that on its sighting.")
        case .add:
            Button("Add") { add(isDescribed: isDescribed) }
                .buttonStyle(RowPillStyle(isFilled: false))
                .disabled(isAdding)
                .accessibilityLabel("Add \(name)")
                .accessibilityHint("Adds it as Heard. You can change that on its sighting.")
        case .review:
            Button("Review", action: review)
                .buttonStyle(RowPillStyle(isFilled: false))
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

/// A row's button: Sew it filled with the tint, Add outlined in the ink, both smaller than the 44 pt they answer to, so the
/// bird stays the main thing on the row. At accessibility sizes it's a rounded rectangle, since its words can wrap.
private struct RowPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    let isFilled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: JournalLayout.outlineRadius(typeSize), style: .continuous)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isFilled ? Color.mossText : Color.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
            .frame(minHeight: 36)
            .background {
                if isFilled {
                    shape.fill(.tint)
                } else {
                    shape.fill(Color.ink.opacity(configuration.isPressed ? 0.15 : 0))
                    shape.strokeBorder(Color.ink, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed && isFilled ? 0.85 : 1) : 0.4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

/// The run's line: "1 new patch waiting" in the tint, then what you already have.
struct HuntSummary: View {
    let hunt: RunHunt

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
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
}
