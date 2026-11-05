import Album
import Identification
import Pack
import SwiftData
import SwiftUI

extension View {
    /// Shows the page after an add that sewed a patch over this screen, bars included, while there is one (issues #51, #132, #135).
    /// - Parameter isCovered: another surface carries its own over this one: this one waits, rather than playing unseen.
    func patchReveal(isCovered: Bool = false) -> some View {
        modifier(PatchRevealOverlay(isCovered: isCovered))
    }
}

private struct PatchRevealOverlay: ViewModifier {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let isCovered: Bool

    func body(content: Content) -> some View {
        let reduceMotion = PatchMotion.reduces(system: systemReduceMotion)
        content
            .overlay {
                if let reveal = run.reveal, !isCovered {
                    NewPatchReveal(reveal: reveal)
                        .id(reveal.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.45), value: run.reveal?.id)
    }
}

/// The words at the top of every page after an add. On a page VoiceOver can read, its focus starts here.
private struct RevealHeading: View {
    let eyebrow: String
    let name: String
    var line: String? = nil
    var takesFocus = true
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(eyebrow)
                .textCase(.uppercase)
                .font(CardFont.editionCompact)
                .tracking(CardFont.editionTracking)
                .foregroundStyle(Color.ink)
                .accessibilityFocused($focused)
            Text(name)
                .font(PatchFont.pageName)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            if let line {
                Text(line)
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(Color.ink)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .boardLabel(horizontal: 12, vertical: 8)
        .onAppear { if takesFocus { focused = true } }
    }
}

private extension View {
    func revealMargins() -> some View {
        padding(.horizontal, JournalLayout.margin)
            .padding(.top, 24)
            .padding(.bottom, JournalLayout.sectionGap)
    }
}

private extension ListeningCoordinator.Reveal {
    var edition: PatchEdition { PatchEdition.of(setID: addition.placement.setID) }

    func artState(in library: PackLibrary) -> PatchArtState {
        library.patchArtState(scientificName: addition.species.scientificName, setID: addition.placement.setID)
    }
}

/// "Your sighting is already saved.": true from before the first thing on these pages.
private struct SavedNote: View {
    var body: some View {
        Text("Your sighting is already saved.")
            .font(JournalFont.attribution)
            .foregroundStyle(Color.ink)
            .boardLabel()
    }
}

/// The way back to the run; once it has ended (a reveal over the run's review), back to the review; with more patches from
/// a glasses run waiting, on to the next.
private struct KeepListeningButton: View {
    @Environment(ListeningCoordinator.self) private var run

    private var title: String {
        if run.waitingCeremonies > 0 { "Next patch" } else if run.state.isActive { "Keep listening" } else { "Done" }
    }

    var body: some View {
        Button(title) {
            run.dismissReveal()
        }
        .buttonStyle(.journalPrimary)
    }
}

/// Undo, while the add's window is open: the toast that also offers it is under this page.
private struct RevealUndoButton: View {
    @Environment(ListeningCoordinator.self) private var run
    let reveal: ListeningCoordinator.Reveal

    var body: some View {
        if run.acknowledgment?.undo == reveal.addition {
            Button("Undo") { run.undo(reveal.addition) }
                .font(JournalFont.supporting.weight(.semibold))
                .foregroundStyle(Color.ink)
                .boardLabel()
                .frame(minHeight: 44)
                .accessibilityLabel("Undo adding \(reveal.commonName)")
        }
    }
}

/// The ceremony of an add that sewed a patch (issue #135, guide pages 5 and 14; replaced #132's Legendary reveal): the
/// stitch-in, then the finished patch on felt with "New patch · Citrus edition" and "Your first Acorn Woodpecker in Los
/// Angeles." Under Reduce Motion or VoiceOver, or without a painting on the phone, it's straight to the finished patch. The
/// sighting was written before this opened, so closing it or a failed share loses nothing. It belongs to the add: it's never
/// replayed, and reopening the patch never shows it. An add on the phone opens it there and then; one on the lens, when the
/// run is over and the app next in front.
private struct NewPatchReveal: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var systemVoiceOver
    let reveal: ListeningCoordinator.Reveal
    /// The patch decoded and the clock over its threads. Once it's here, the stitch-in is on, whatever the settings do.
    @State private var prepared: (art: PatchArt, loaded: PatchTextures.Loaded, timeline: StitchTimeline)?

    private var art: PatchArt? { reveal.artState(in: library).art }

    private var stitches: Bool {
        StitchCeremony.stitches(
            reduceMotion: PatchMotion.reduces(system: systemReduceMotion), voiceOver: PatchMotion.voiceOver(system: systemVoiceOver), hasArt: art != nil
        )
    }

    var body: some View {
        Group {
            if reveal.hasPlayed {
                NewPatchPage(reveal: reveal, decoded: prepared?.loaded)
            } else if let prepared {
                SewingPage(reveal: reveal, art: prepared.art, decoded: prepared.loaded, timeline: prepared.timeline)
            } else if stitches {
                // A moment, while the patch decodes: its cloth.
                SewingPage(reveal: reveal, art: nil, decoded: nil, timeline: StitchTimeline(threads: []))
            } else {
                NewPatchPage(reveal: reveal, decoded: nil)
            }
        }
        .patchSheetBackground()
        .holdsPatchLight()
        .accessibilityAddTraits(.isModal)
        .task { await prepare() }
    }

    /// Decodes the patch and reads its threads. Decided once, on opening: no stitching now is none later, whatever the
    /// settings do while the page is up, and a patch that can't be read goes straight to its finished page.
    private func prepare() async {
        guard !reveal.hasPlayed else { return }
        guard stitches, let art else {
            run.finishCeremony()
            return
        }
        let loaded = await PatchTextures.load(art, size: .full)
        guard !Task.isCancelled else { return }
        let threads = if let loaded { await PatchTextures.threads(of: loaded, art: art) } else { [StitchThread]() }
        guard !Task.isCancelled else { return }
        guard let loaded, !threads.isEmpty else {
            run.finishCeremony()
            return
        }
        prepared = (art, loaded, Self.timeline(threads))
    }

    private static func timeline(_ threads: [StitchThread]) -> StitchTimeline {
        var timeline = StitchTimeline(threads: threads)
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "stitchInSeconds")
        if seconds > 0 { timeline.duration = seconds }
        timeline.loops = UserDefaults.standard.bool(forKey: "stitchInSweep")
        #endif
        return timeline
    }
}

/// The stitch-in itself. The whole page is one button, since a tap anywhere finishes it. Only the patch redraws with the
/// clock; the caption and the haptic change with the thread.
private struct SewingPage: View {
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.dynamicTypeSize) private var typeSize
    let reveal: ListeningCoordinator.Reveal
    /// Nil while it decodes: the bare cloth, and the clock hasn't started.
    let art: PatchArt?
    let decoded: PatchTextures.Loaded?
    let timeline: StitchTimeline
    @State private var startedAt = Date.now
    @State private var thread: Int?
    #if DEBUG
    @State private var frameLog: PatchFrameLog?
    #endif

    private var caption: String { timeline.caption(for: thread) }

    private var swatch: Color {
        guard let thread, timeline.threads.indices.contains(thread) else { return PatchMaterial.transferPen }
        let sewn = timeline.threads[thread]
        return Color(.sRGB, red: sewn.red, green: sewn.green, blue: sewn.blue)
    }

    var body: some View {
        Button(action: finish) {
            VStack(spacing: 18) {
                RevealHeading(eyebrow: "Sewing your patch", name: reveal.commonName, line: PatchText.revealNumberLine(reveal.addition.placement), takesFocus: false)
                patch
                    .frame(maxWidth: typeSize.isAccessibilitySize ? 200 : 280)
                    .padding(.vertical, 8)
                HStack(spacing: 8) {
                    Circle()
                        .fill(swatch)
                        .overlay(Circle().strokeBorder(Color.ink.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 14, height: 14)
                    Text(caption)
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.ink)
                }
                .boardLabel()
                SavedNote()
            }
            .multilineTextAlignment(.center)
            .revealMargins()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sewing your \(reveal.commonName) patch")
        .accessibilityValue(caption)
        .accessibilityHint("Finishes it.")
        .accessibilityIdentifier("stitch-in")
        // A light, optional tick at each thread: the system's haptics setting turns it off.
        .sensoryFeedback(.impact(weight: .light), trigger: thread) { _, now in now != nil }
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.bool(forKey: "stitchInSweep") { frameLog = PatchFrameLog(category: "stitch-in") }
        }
        .onDisappear { frameLog?.stop() }
        #endif
    }

    @ViewBuilder private var patch: some View {
        if let art {
            // `.animation` redraws each display frame, so this leaf and the shader under it, and nothing above: the frame
            // times are measured with `-stitchInSweep YES`.
            TimelineView(.animation) { context in
                let frame = timeline.frame(at: context.date.timeIntervalSince(startedAt))
                PatchView(art: art, edition: reveal.edition, face: .stitching(sewnTo: frame.sewnTo), size: .full, decoded: decoded)
                    .onChange(of: frame.thread) { _, now in thread = now }
                    .onChange(of: frame.isDone) { _, done in if done { finish() } }
            }
        } else {
            Color.clear
                .aspectRatio(reveal.edition.aspect, contentMode: .fit)
                .overlay { PatchOutline(shape: reveal.edition.shape).fill(reveal.edition.twill) }
        }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.3)) { run.finishCeremony() }
    }
}

/// The finished patch on felt: "New patch · Citrus edition", "Your first Acorn Woodpecker in Los Angeles.", Keep listening.
private struct NewPatchPage: View {
    @Environment(PackLibrary.self) private var library
    @Environment(ListeningCoordinator.self) private var run
    @Environment(\.modelContext) private var context
    @Environment(\.openCollection) private var openCollection
    @Environment(\.dynamicTypeSize) private var typeSize
    let reveal: ListeningCoordinator.Reveal
    let decoded: PatchTextures.Loaded?
    @State private var sharing: Sighting?
    /// Set once on appearing: the haptic's trigger.
    @State private var appeared = false

    /// Fetched, not `model(for:)`: an undone add's id would come back as a placeholder that faults.
    private var sighting: Sighting? {
        let id = reveal.addition.sightingID
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    var body: some View {
        let sighting = sighting
        ScrollView {
            VStack(spacing: 18) {
                RevealHeading(eyebrow: reveal.eyebrow, name: reveal.commonName, line: PatchText.revealNumberLine(reveal.addition.placement))
                PatchView(state: reveal.artState(in: library), edition: reveal.edition, size: .full, tag: reveal.commonName, decoded: decoded)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? 200 : 280)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PatchText.spoken(name: reveal.commonName, edition: reveal.addition.placement.editionLabel, count: reveal.addition.patchCount, sewn: sighting?.confirmedAt ?? .now, beingSewn: reveal.artState(in: library) == .beingSewn))
                    .accessibilityIdentifier("revealed-patch")
                Text("\(reveal.title).")
                    .font(.system(.body, design: .serif).italic())
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel(horizontal: 12, vertical: 8)
                    .accessibilityLabel(reveal.title)
                VStack(spacing: 10) {
                    KeepListeningButton()
                    if let sighting {
                        Button {
                            sharing = sighting
                        } label: {
                            Label("Share this patch", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.journalOutlined)
                    }
                    // A long glasses run can sew a dozen. Going to the collection waits for the last of them.
                    Group {
                        if run.waitingCeremonies > 0 {
                            Button("Skip the rest · \(run.waitingCeremonies) more") { run.skipCeremonies() }
                        } else {
                            Button("See it in my collection") {
                                run.dismissReveal()
                                openCollection()
                            }
                        }
                    }
                    .font(JournalFont.supporting.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .boardLabel()
                    .frame(minHeight: 44)
                    RevealUndoButton(reveal: reveal)
                    SavedNote()
                }
            }
            .revealMargins()
        }
        .scrollBounceBehavior(.basedOnSize)
        // A light, optional haptic: the system's haptics setting turns it off.
        .sensoryFeedback(.impact(weight: .light), trigger: appeared)
        .onAppear { appeared = true }
        .sheet(item: $sharing) { sighting in
            ShareCardView(sighting: sighting)
        }
    }
}
