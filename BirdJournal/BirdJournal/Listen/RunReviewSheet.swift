import Album
import Identification
import Pack
import SwiftUI

/// The calm review after a run ends (issue #28): every species heard, what was added, and Sew it, Add or Review for the rest.
/// In memory only; a named outing is deferred.
struct RunReviewSheet: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openCollection) private var openCollection
    @State private var reviewing: Candidate?
    @State private var path = NavigationPath()
    @Environment(CollectionStore.self) private var collectionStore

    var body: some View {
        NavigationStack(path: $path) {
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    HuntSummary(hunt: run.hunt(in: collectionStore.collection), isCentred: false)
                        .padding(.top, 4)
                    if let startedAt = run.startedAt {
                        Text("Started \(startedAt.formatted(date: .omitted, time: .shortened)), listened for \(ElapsedTime.text(from: startedAt, to: .now))")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 4)
                    }
                    VStack(spacing: 0) {
                        ForEach(run.orderedCandidates) { candidate in
                            CandidateRow(candidate: candidate) {
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
            .holdsPatchLight()
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
        .patchStack(lifts: false) { path.append($0) }
        .patchReveal()
        // Dragged away from under the page, it would have to start again over the tabs; Keep listening closes it first.
        .interactiveDismissDisabled(run.reveal != nil)
        // The patch tapped on a reveal over this sheet: the review closes, as Done does, so the collection shows.
        .environment(\.openCollection) { board in
            dismiss()
            openCollection(board)
        }
        .onDisappear { run.dismissEnded() }
    }
}
