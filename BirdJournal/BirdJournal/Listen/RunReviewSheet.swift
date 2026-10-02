import Identification
import SwiftUI

/// The calm review after a run ends (issue #28): every species heard, what was added, and Review for the rest. In
/// memory only; a named outing is deferred.
struct RunReviewSheet: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.dismiss) private var dismiss
    @State private var reviewing: Candidate?

    var body: some View {
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.summary)
                        .font(JournalFont.body)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 4)
                    if let startedAt = run.startedAt {
                        Text("Started \(startedAt.formatted(date: .omitted, time: .shortened)) · listened for \(ElapsedTime.text(from: startedAt, to: .now))")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.top, 4)
                    }
                    VStack(spacing: 0) {
                        ForEach(run.orderedCandidates) { candidate in
                            CandidateRow(candidate: candidate, isAdded: run.isAdded(candidate), startedAt: run.startedAt) {
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
                    Toast(text: acknowledgment.text, undo: acknowledgment.undo.map { addition in { run.undo(addition) } })
                        .padding(.bottom, 8)
                }
            }
        }
        .onDisappear { run.dismissEnded() }
    }
}
