import Album
import SwiftData
import SwiftUI

extension View {
    /// Shows the coordinator's Legendary reveal over this screen, bars included, while there is one (issue #51).
    func legendaryReveal() -> some View {
        modifier(LegendaryRevealOverlay())
    }
}

private struct LegendaryRevealOverlay: ViewModifier {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if let reveal = run.reveal {
                    LegendaryRevealView(reveal: reveal)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.45), value: run.reveal)
    }
}

/// The Legendary reveal after an add that was the birder's first of a species (style guide v0.2, "Identification and
/// first discovery flow"): the card central with "Your first House Finch", Share this discovery and Back to my
/// collection. The sighting was written before this opened, so closing it or a failed share loses nothing; Undo stays
/// while the add's window is open.
private struct LegendaryRevealView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.modelContext) private var context
    @Environment(\.openCollection) private var openCollection
    @Environment(\.dynamicTypeSize) private var typeSize
    let reveal: ListeningCoordinator.Reveal
    @State private var sharing: Sighting?

    /// Fetched, not `model(for:)`: an undone add's id would come back as a placeholder that faults.
    private var sighting: Sighting? {
        let id = reveal.addition.sightingID
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Button {
                        run.dismissReveal()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(Color.inkSecondary)
                    .accessibilityLabel("Close")
                }
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.title)
                        .foregroundStyle(Color.goldInk)
                        .accessibilityHidden(true)
                    Text(reveal.title)
                        .font(JournalFont.title)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Added to your journal. Your earliest card of each species is Legendary.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                if let sighting {
                    CardTile(sighting: sighting, isLegendary: true, placement: reveal.addition.placement)
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 260)
                }
                VStack(spacing: 10) {
                    Button("Back to my collection") {
                        run.dismissReveal()
                        openCollection()
                    }
                    .buttonStyle(.journalPrimary)
                    if let sighting {
                        Button {
                            sharing = sighting
                        } label: {
                            Label("Share this discovery", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.journalOutlined)
                    }
                    if run.acknowledgment?.undo == reveal.addition {
                        Button("Undo") { run.undo(reveal.addition) }
                            .font(JournalFont.body.weight(.semibold))
                            .foregroundStyle(Color.moss)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Undo adding \(reveal.commonName)")
                    }
                }
            }
            .padding(.horizontal, JournalLayout.margin)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.goldWash.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
        .sheet(item: $sharing) { sighting in
            SharePostcardView(sighting: sighting)
        }
    }
}
