import Album
import Identification
import Pack
import SwiftData
import SwiftUI

/// One sighting in full (issue #28): the glasses snapshot and the reference photo kept apart and labelled, the record
/// (species, when, roughly where, source), the birder's note, the explained match, and the way to the bird's profile,
/// to sharing and to a recoverable removal.
struct SightingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaceNames.self) private var places
    @Environment(PackLibrary.self) private var library
    @Environment(JournalEdits.self) private var edits
    let id: PersistentIdentifier
    @State private var note = ""
    @State private var isSharing = false
    @State private var confirmingRemoval = false
    @FocusState private var editingNote: Bool

    /// Fetched, not `model(for:)`: a deleted id would come back as a placeholder that faults on first access.
    private var sighting: Sighting? {
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    var body: some View {
        if let sighting {
            let reference = library.species(scientificName: sighting.scientificName)
            let commonName = library.commonName(for: sighting)
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    if sighting.frameImagePath != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            FrameImage(frameImagePath: sighting.frameImagePath)
                                .aspectRatio(4 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                                .accessibilityLabel("Your glasses snapshot from this sighting")
                            Text("Your glasses snapshot · the centre of the camera frame when you added the bird. It may show the surroundings rather than the bird.")
                                .font(JournalFont.attribution)
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .padding(.top, 4)
                    }

                    Text(commonName)
                        .font(JournalFont.title)
                        .foregroundStyle(Color.ink)
                        .padding(.top, sighting.frameImagePath != nil ? 18 : 4)
                    Text(sighting.scientificName)
                        .font(JournalFont.scientific)
                        .foregroundStyle(Color.inkSecondary)

                    VStack(spacing: 0) {
                        FactRow(label: "When", value: sighting.confirmedAt.formatted(date: .long, time: .shortened))
                        RowRule()
                        FactRow(label: "Where", value: placeText(for: sighting))
                        RowRule()
                        FactRow(label: "Heard with", value: sighting.source == .glasses ? "Ray-Ban Display" : "iPhone microphone")
                    }
                    .padding(.top, 16)

                    SectionTitle(text: "Your note")
                    TextField("Add a note", text: $note, axis: .vertical)
                        .font(JournalFont.body)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2...8)
                        .padding(14)
                        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                        .focused($editingNote)
                        .padding(.top, 12)
                        .onChange(of: editingNote) { _, editing in
                            if !editing { edits.setNote(note, on: sighting) }
                        }
                        .accessibilityLabel("Your note")

                    if let reference, let photo = reference.species.photos.first {
                        SectionTitle(text: "Reference photo")
                        AttributedImage(pack: reference.pack, photo: photo, caption: "Reference photo, not your bird")
                            .padding(.top, 12)
                    }

                    SectionTitle(text: "About this bird")
                    if let summary = reference?.species.summary, !summary.isEmpty {
                        Text(summary)
                            .font(JournalFont.body)
                            .foregroundStyle(Color.ink)
                            .padding(.top, 12)
                    } else if reference == nil {
                        Text("No photos or notes for this bird are in your bird packs. It was identified by name.")
                            .font(JournalFont.body)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 12)
                    }
                    NavigationLink(value: Route.species(scientificName: sighting.scientificName, commonName: commonName)) {
                        Label("Open in Field Guide", systemImage: "book")
                    }
                    .buttonStyle(.journalOutlined)
                    .padding(.top, 12)

                    SectionTitle(text: "Identification")
                    SightingMatchDetails(sighting: sighting)
                        .padding(.top, 8)

                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label("Remove from journal", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .padding(.top, JournalLayout.sectionGap)
                }
            }
            .navigationTitle(commonName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSharing = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $isSharing) {
                SharePostcardView(sighting: sighting)
            }
            .confirmationDialog("Remove this sighting from your journal?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    edits.remove(sighting, commonName: commonName)
                    dismiss()
                }
            } message: {
                Text("You can undo this for a few seconds afterwards.")
            }
            .task(id: id) {
                note = sighting.note ?? ""
                if let location = sighting.location { await places.resolve(location) }
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "autoShare") {
                    UserDefaults.standard.removeObject(forKey: "autoShare")
                    try? await Task.sleep(for: .milliseconds(600))
                    isSharing = true
                }
                #endif
            }
            .onDisappear {
                if let sighting = self.sighting { edits.setNote(note, on: sighting) }
            }
        } else {
            ContentUnavailableView("Sighting removed", systemImage: "bird")
        }
    }

    /// The approximate place: the name when known, else the coordinate to two decimals (about a kilometre).
    private func placeText(for sighting: Sighting) -> String {
        guard let location = sighting.location else { return "No location was recorded" }
        return places.name(for: location).map { "Near \($0)" } ?? "Near \(location.formatted)"
    }
}

/// A label and a value on one line, wrapping when the value is long.
struct FactRow: View {
    let label: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(JournalFont.body).foregroundStyle(Color.ink).fixedSize()
                Spacer(minLength: 16)
                Text(value).font(JournalFont.body).foregroundStyle(Color.inkSecondary).multilineTextAlignment(.trailing).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(JournalFont.body).foregroundStyle(Color.ink)
                Text(value).font(JournalFont.body).foregroundStyle(Color.inkSecondary)
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// The saved score, in the same disclosure as the live one.
private struct SightingMatchDetails: View {
    let sighting: Sighting
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Model score", value: sighting.soundConfidence.formatted(.number.precision(.fractionLength(2))))
                Text("BirdNET's best single-window score for this species when it was added, between 0 and 1. It is not a calibrated probability, and it does not make the sighting certain: you did, when you added it.")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(JournalFont.supporting)
            .padding(.top, 6)
        } label: {
            Label("About this match", systemImage: "waveform.badge.magnifyingglass")
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
        }
        .tint(Color.moss)
    }
}
