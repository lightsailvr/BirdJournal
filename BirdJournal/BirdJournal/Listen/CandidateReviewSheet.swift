import Album
import Identification
import Pack
import SwiftData
import SwiftUI

/// Reviewing a candidate (issue #28): the bird's profile with the match details, and the explicit add: "Add and sew
/// patch" when the bird is new to the place, else "Add sighting" (issue #132).
/// A detection is not an observation until the birder says so here (or on the lens).
struct CandidateReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidate: Candidate

    var body: some View {
        NavigationStack {
            CandidateReviewView(candidate: candidate)
                .appDestinations()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}

/// The review itself: the profile with the match, and the add action pinned at the bottom. Pushed inside the run
/// review, presented as a sheet from the live list.
struct CandidateReviewView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let candidate: Candidate
    @State private var isAdding = false
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]

    /// The sightings of the bird in the patch an add here would join; 0 when the add would sew a new patch.
    private var seenHere: Int {
        library.collection(of: sightings).count(ofSpeciesID: candidate.species.birdnetLabel, at: run.coordinate)
    }

    var body: some View {
            BirdProfileView(
                scientificName: candidate.species.scientificName,
                commonName: candidate.species.commonName,
                match: candidate
            )
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isAdded(candidate) {
                        Label("Added · seen \(CardCollection.Patch.times(seenHere)) here", systemImage: "checkmark.circle.fill")
                            .font(JournalFont.supporting.weight(.medium))
                            .foregroundStyle(Color.moss)
                        Button(isAdding ? "Adding…" : "Add another sighting") { add() }
                            .buttonStyle(.journalOutlined)
                            .disabled(isAdding)
                    } else {
                        Button {
                            add()
                        } label: {
                            Label(isAdding ? "Adding…" : seenHere == 0 ? "Add and sew patch" : "Add sighting", systemImage: "plus")
                        }
                        .buttonStyle(.journalPrimary)
                        .disabled(isAdding)
                        // Heard is the default; Seen is a deliberate change on the card's back (#52).
                        Text(seenHere == 0 ? "New to you here. Added as Heard; you can mark it Seen on the card." : "Seen \(CardCollection.Patch.times(seenHere)) here. Added as Heard; you can mark it Seen on the card.")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.vertical, 12)
                .background(.bar)
            }
    }

    private func add() {
        isAdding = true
        Task {
            await run.add(candidate)
            isAdding = false
            dismiss()
        }
    }
}

/// The explained score disclosure: what the model reported, and what it does not mean.
struct MatchDetails: View {
    let candidate: Candidate
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Model score", value: candidate.score.formatted(.number.precision(.fractionLength(2))))
                LabeledContent("Heard in", value: "\(candidate.windowsAboveThreshold) \(candidate.windowsAboveThreshold == 1 ? "window" : "windows") of 3 seconds")
                LabeledContent("First heard", value: Self.offset(candidate.firstHeardAt))
                Text("The score is BirdNET's best single-window output for this species this run, between 0 and 1. It is not a calibrated probability that the identification is right, and a high score does not make a sighting certain: that is your call.")
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

    static func offset(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d into the run", total / 60, total % 60)
    }
}
