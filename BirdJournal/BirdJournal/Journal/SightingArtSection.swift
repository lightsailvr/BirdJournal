import Album
import Pack
import SwiftUI

/// A sighting's own art (issue #134 moved it here from the card's page; #137 retires it): the painting or the
/// embellished photo with its label, what's under way, and the controls for it. Nothing shows for a sighting that has
/// none and can't ask for any.
struct SightingArtSection: View {
    @Environment(PackLibrary.self) private var library
    @Environment(ArtJobs.self) private var art
    let sighting: Sighting
    let setID: String?

    var body: some View {
        let cardArt = CardArtView.art(for: sighting, library: library, setID: setID)
        let commonName = library.commonName(for: sighting)
        let hasOwn = sighting.art.sceneStatus != .none || sighting.art.photoStatus != .none
        if hasOwn || art.isAvailable {
            SectionTitle(text: "Art")
            VStack(alignment: .leading, spacing: 10) {
                CardArtView(art: cardArt, commonName: commonName)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Card art: \(cardArt.label)")
                    .accessibilityIdentifier("card-art")
                Text(cardArt.provenance)
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = CardText.sceneArtLine(sighting.art.sceneStatus) {
                    Label(line, systemImage: sighting.art.sceneStatus == .failed ? "exclamationmark.circle" : "paintbrush.pointed")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(line)
                        .accessibilityIdentifier("card-art-status")
                }
                CardArtActions(sighting: sighting)
                PhotoArtActions(sighting: sighting)
            }
            .padding(.top, 12)
        }
    }
}

/// Scene art's controls under the card (issue #68, spec v2 stories 50 and 52): Try again and Use pack art on a card
/// with a painting, Use painted art to go back to it, Retry art and Keep current art after a failure, and Paint this
/// scene on a glasses card never painted (the public launch's ordinary adds, issue #69), with "N left today". Asking for a new
/// painting needs the account (`ArtJobs.isAvailable`); choosing between the painting and the pack art doesn't. A card
/// whose job is pending polls it while it is open.
private struct CardArtActions: View {
    @Environment(ArtJobs.self) private var art
    let sighting: Sighting
    @State private var asking = false

    var body: some View {
        let status = sighting.art.sceneStatus
        Group {
            switch status {
            case .ready(let showsPackArt):
                HStack(spacing: 10) {
                    if art.isAvailable {
                        Button("Try again", systemImage: "arrow.clockwise") { paintAgain() }
                            .accessibilityHint("Paints a new picture. This one stays until the new one is ready.")
                            .accessibilityIdentifier("card-art-try-again")
                    }
                    if showsPackArt {
                        Button("Use painted art", systemImage: "photo.artframe") { art.setShowsPackArt(false, on: sighting) }
                            .accessibilityIdentifier("card-art-use-painted")
                    } else {
                        Button("Use pack art", systemImage: "square.stack") { art.setShowsPackArt(true, on: sighting) }
                            .accessibilityIdentifier("card-art-use-pack")
                    }
                }
            case .failed:
                HStack(spacing: 10) {
                    if art.isAvailable {
                        Button("Retry art", systemImage: "arrow.clockwise") { paintAgain() }
                            .accessibilityIdentifier("card-art-retry")
                    }
                    Button("Keep current art", systemImage: "checkmark") { art.keepCurrentArt(sighting) }
                        .accessibilityIdentifier("card-art-keep")
                }
            case .none:
                // At the public launch an ordinary add isn't painted automatically: scene art is the birder's to ask
                // for, within the day's allowance (issue #69). A card that was never painted (signed out at the add)
                // gets the same.
                if art.isAvailable, sighting.frameImagePath != nil {
                    Button {
                        paintAgain()
                    } label: {
                        Label("Paint this scene", systemImage: "paintbrush.pointed").frame(maxWidth: .infinity)
                    }
                    .accessibilityHint("Paints the bird into your glasses photo.")
                    .accessibilityIdentifier("card-art-paint")
                }
            case .pending:
                EmptyView()
            }
        }
        .buttonStyle(.journalOutlined)
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if let refusal = art.refusal(for: sighting, kind: .scene) {
                Text(refusal)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("card-art-refusal")
            }
            // "N left today" beside the buttons that spend one (issue #69); nothing in the friends phase.
            if art.isAvailable, status != .pending, sighting.frameImagePath != nil || status != .none, let line = CardText.allowanceLine(art.allowance) {
                Text(line)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("card-art-allowance")
            }
        }
        .task { await art.refreshAllowance() }
        .disabled(asking)
        .task(id: sighting.art.pendingJobs.map(\.id)) {
            // While this card waits, look in on its jobs now and then: the painting machine may come back any time.
            while !Task.isCancelled, !sighting.art.pendingJobs.isEmpty {
                await art.refresh(sighting)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func paintAgain() {
        asking = true
        Task {
            await art.paintAgain(sighting)
            asking = false
        }
    }
}
