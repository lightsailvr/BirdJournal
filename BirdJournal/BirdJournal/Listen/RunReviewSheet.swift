import Album
import Identification
import Pack
import SwiftData
import SwiftUI

/// The calm review after a run ends (issue #28): every species heard, what was added, and Review for the rest. In
/// memory only; a named outing is deferred.
struct RunReviewSheet: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openCollection) private var openCollection
    @Environment(PackLibrary.self) private var library
    @State private var reviewing: Candidate?
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]

    var body: some View {
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.summary)
                        .font(JournalFont.body)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 4)
                    if let startedAt = run.startedAt {
                        Text("Started \(startedAt.formatted(date: .omitted, time: .shortened)), listened for \(ElapsedTime.text(from: startedAt, to: .now))")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 4)
                    }
                    let collection = library.collection(of: sightings)
                    VStack(spacing: 0) {
                        ForEach(run.orderedCandidates) { candidate in
                            CandidateRow(candidate: candidate, isAdded: run.isAdded(candidate), startedAt: run.startedAt, seenHere: collection.count(ofSpeciesID: candidate.species.birdnetLabel, at: run.coordinate)) {
                                reviewing = candidate
                            }
                            RowRule()
                        }
                    }
                    .padding(.top, 16)
                    Text("Only the birds you add are kept. The rest are forgotten when you close this.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Your run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $reviewing) { candidate in
                CandidateReviewView(candidate: candidate)
            }
            .appDestinations()
            .safeAreaInset(edge: .bottom) {
                if let acknowledgment = run.acknowledgment {
                    Toast(text: acknowledgment.text, undo: acknowledgment.undo.map { addition in { run.undo(addition) } }, ticksFrom: acknowledgment.ticksFrom)
                        .id(acknowledgment.id)
                        .padding(.bottom, 8)
                }
            }
        }
        .patchReveal()
        // Dragged away from under the page, it would have to start again over the tabs; Keep listening closes it first.
        .interactiveDismissDisabled(run.reveal != nil)
        // See it in my collection from a reveal over this sheet: the review closes, as Done does, so the collection shows.
        .environment(\.openCollection) {
            dismiss()
            openCollection()
        }
        .onDisappear { run.dismissEnded() }
    }
}
