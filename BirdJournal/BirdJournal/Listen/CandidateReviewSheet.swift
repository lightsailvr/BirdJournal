import Album
import Identification
import Pack
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
    @Environment(\.dismiss) private var dismiss
    let candidate: Candidate
    @State private var isAdding = false
    /// How the birder met the bird: Heard unless they say otherwise here (guide board 03) or later on the sighting.
    @State private var method = SightingMethod.heard
    @Environment(CollectionStore.self) private var collectionStore

    /// The sightings of the bird in the patch an add here would join; 0 when the add would sew a new patch.
    private var seenHere: Int {
        collectionStore.collection.count(ofSpeciesID: candidate.species.birdnetLabel, at: run.coordinate)
    }

    var body: some View {
            BirdProfileView(
                scientificName: candidate.species.scientificName,
                commonName: candidate.species.commonName,
                match: candidate
            )
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isAdded(candidate) {
                        Label("Added, seen \(CardCollection.Patch.times(seenHere)) here", systemImage: "checkmark.circle.fill")
                            .font(JournalFont.supporting.weight(.medium))
                            .foregroundStyle(Color.moss)
                        Button(isAdding ? "Adding…" : "Add another sighting") { add() }
                            .buttonStyle(.journalOutlined)
                            .disabled(isAdding)
                    } else {
                        Picker("How you met it", selection: $method) {
                            ForEach(SightingMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("review-method")
                        Button {
                            add()
                        } label: {
                            Label(isAdding ? "Adding…" : seenHere == 0 ? "Add and sew patch" : "Add sighting", systemImage: "plus")
                        }
                        .buttonStyle(.journalPrimary)
                        .disabled(isAdding)
                        Text(seenHere == 0 ? "New to you here." : "Seen \(CardCollection.Patch.times(seenHere)) here.")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, JournalLayout.margin)
                .padding(.vertical, 12)
            }
    }

    private func add() {
        isAdding = true
        Task {
            await run.add(candidate, method: method)
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
