import Album
import SwiftData
import SwiftUI

extension View {
    /// Shows the coordinator's new-patch reveal over this screen, bars included, while there is one (issues #51, #132).
    func patchReveal() -> some View {
        modifier(PatchRevealOverlay())
    }
}

private struct PatchRevealOverlay: ViewModifier {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if let reveal = run.reveal {
                    PatchRevealView(reveal: reveal)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.45), value: run.reveal)
    }
}

/// The new-patch reveal after an add that sewed a patch, the species' first sighting in its placement (issue #132, of
/// #131; before it the Legendary reveal of #51 and #117): "New patch · Citrus edition", "Your first Black Phoebe in Los
/// Angeles.", the card in a restrained orbit, a light haptic as it opens, and Keep listening as the way back, with Share
/// and the collection after it. The sighting was written before this opened, so closing it or a failed share loses
/// nothing ("Your sighting is already saved"); Undo stays while the add's window is open. It belongs to the add:
/// reopening the patch never shows it again. Slice #135 replaces the card with the stitched patch.
private struct PatchRevealView: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.modelContext) private var context
    @Environment(\.openCollection) private var openCollection
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reveal: ListeningCoordinator.Reveal
    @State private var sharing: Sighting?
    /// Set once on appearing: the haptic's trigger and the orbit's one drawing.
    @State private var appeared = false

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
                ZStack {
                    Text(reveal.eyebrow)
                        .font(.system(.subheadline, design: .serif))
                        .tracking(1.2)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.horizontal, 48)
                    HStack {
                        Spacer()
                        Button {
                            run.dismissReveal()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .overlay(Circle().strokeBorder(Color.rule, lineWidth: 1))
                        }
                        .foregroundStyle(Color.inkSecondary)
                        .accessibilityLabel("Close")
                    }
                }
                Text("\(reveal.title).")
                    .font(JournalFont.largeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(reveal.title)
                    .accessibilityAddTraits(.isHeader)
                if let sighting {
                    CardTile(sighting: sighting, placement: reveal.addition.placement)
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 240)
                        .padding(.vertical, typeSize.isAccessibilitySize ? 0 : 22)
                        .background {
                            if !typeSize.isAccessibilitySize {
                                RevealOrbit(drawn: appeared || reduceMotion)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                Text("The first time you find a bird in a place, you sew its patch. Every sighting after adds to its count.")
                    .font(JournalFont.body)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    // The way back to the run; once it has ended (a reveal over the run's review), back to the review.
                    Button(run.state.isActive ? "Keep listening" : "Done") {
                        run.dismissReveal()
                    }
                    .buttonStyle(.journalPrimary)
                    if let sighting {
                        Button {
                            sharing = sighting
                        } label: {
                            Label("Share this discovery", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.journalOutlined)
                    }
                    Button("See it in my collection") {
                        run.dismissReveal()
                        openCollection()
                    }
                    .font(JournalFont.supporting.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(minHeight: 44)
                    if run.acknowledgment?.undo == reveal.addition {
                        Button("Undo") { run.undo(reveal.addition) }
                            .font(JournalFont.supporting.weight(.semibold))
                            .foregroundStyle(Color.moss)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Undo adding \(reveal.commonName)")
                    }
                    Text("Your sighting is already saved.")
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.horizontal, JournalLayout.margin)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            ZStack {
                Color.paper
                // A soft light behind the card: the reveal's one wash.
                RadialGradient(colors: [Color.moss.opacity(0.14), Color.paper.opacity(0)], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 10, endRadius: 360)
            }
            .ignoresSafeArea()
        }
        .accessibilityAddTraits(.isModal)
        // A light, optional haptic: the system's haptics setting turns it off.
        .sensoryFeedback(.impact(weight: .light), trigger: appeared)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9).delay(0.15)) { appeared = true }
        }
        .sheet(item: $sharing) { sighting in
            ShareCardView(sighting: sighting)
        }
    }
}

/// The restrained orbit behind the revealed card (guide 1.0 page 15): one fine ellipse with two small stones on it, drawn
/// once as the reveal opens and then still. No glints, no spin (page 19).
private struct RevealOrbit: View {
    let drawn: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let rect = CGRect(x: -size.width * 0.2, y: 0, width: size.width * 1.4, height: size.height)
            ZStack {
                Ellipse()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Color.moss.opacity(0.6), lineWidth: 1)
                    .rotationEffect(.degrees(-90))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                ForEach([0.12, 0.62], id: \.self) { turn in
                    let angle = 2 * Double.pi * turn
                    Circle()
                        .fill(Color.moss)
                        .frame(width: 6, height: 6)
                        .position(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
                        .opacity(drawn ? 1 : 0)
                }
            }
        }
    }
}
