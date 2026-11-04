import Album
import Pack
import SwiftData
import SwiftUI

/// One patch (issue #134, guide page 6): large on felt, lit by the tilt, with its name, edition and count set in type below
/// it, never stitched. Tapping it, or the visible Turn over, flips the object to its paper card. Opening a patch shows the
/// patch. The face hosts no controls beyond the turn: sightings, notes, photos and sources open from the card.
struct PatchDetailView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(Sighting.newestFirst()) private var allSightings: [Sighting]
    let key: CardCollection.Patch.Key
    @State private var showsBack = false
    @State private var isSharing = false
    @AccessibilityFocusState private var turnFocused: Bool

    /// The footprint at default text size (guide page 10), on a phone wide enough for it.
    private static let footprint = CGSize(width: 330, height: 470)

    private var reduceMotion: Bool { PatchMotion.reduces(system: systemReduceMotion) }

    var body: some View {
        let collection = library.collection(of: allSightings)
        if let patch = collection.patch(key: key) {
            let name = PatchText.name(of: patch, library: library)
            let sightings = patch.ownSightings(among: allSightings)
            ScrollView {
                VStack(spacing: 16) {
                    CollectibleCard(showsBack: showsBack, rotates: !reduceMotion, backGrows: typeSize.isAccessibilitySize) {
                        patchFace(patch, name: name)
                    } back: {
                        PaperCardView(patch: patch, sightings: sightings, name: name, isReadingView: typeSize.isAccessibilitySize)
                    }
                    .frame(maxWidth: Self.footprint.width)
                    under(patch, name: name)
                    Button(action: turn) {
                        Label(showsBack ? "Turn back" : "Turn over", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    .buttonStyle(.journalOutlined)
                    .accessibilityValue(showsBack ? "Paper card" : "Patch")
                    .accessibilityHint(showsBack ? "Shows the patch." : "Shows its paper card, with its story and your sightings.")
                    .accessibilityIdentifier("card-flip")
                    .accessibilityFocused($turnFocused)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, JournalLayout.sectionGap)
            }
            .background { BoardMaterial().ignoresSafeArea() }
            .holdsPatchLight()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // The object gets the whole height (design guide page 10); back returns to the tabs.
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSharing = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: showsBack)
            .sheet(isPresented: $isSharing) {
                if let latest = sightings.first {
                    ShareCardView(sighting: latest)
                }
            }
            .task {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "autoCardBack") {
                    UserDefaults.standard.removeObject(forKey: "autoCardBack")
                    showsBack = true
                }
                #endif
            }
        } else {
            // The last sighting was removed from under the page.
            ContentUnavailableView("Patch unpicked", systemImage: "bird", description: Text("Its last sighting here was removed."))
                .background(Color.paper)
        }
    }

    /// The front: the patch centred in the footprint. Tapping it turns it.
    private func patchFace(_ patch: CardCollection.Patch, name: String) -> some View {
        Button(action: turn) {
            PatchView(
                art: library.patchArt(scientificName: patch.scientificName, setID: patch.placement.setID),
                edition: PatchEdition.of(setID: patch.placement.setID), size: .full, tag: name
            )
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 300 : Self.footprint.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PatchText.spoken(patch, name: name))
        .accessibilityHint("Turn over for its story.")
        .accessibilityIdentifier("patch-face")
    }

    /// What sits below the object: the patch's words, set in type; on the card's side, where its details open.
    @ViewBuilder private func under(_ patch: CardCollection.Patch, name: String) -> some View {
        if showsBack {
            Text("Your notes, photos and every sighting open from this side.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 4) {
                Text(PatchText.editionLine(patch.placement))
                    .textCase(.uppercase)
                    .font(CardFont.editionCompact)
                    .tracking(CardFont.editionTracking)
                    .foregroundStyle(Color.ink)
                Text(name)
                    .font(PatchFont.pageName)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(PatchText.pageLine(patch))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.ink)
                    .accessibilityIdentifier("patch-count")
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Turns the object over and says which face is up. A tap during a turn retargets it, so rapid taps settle on one
    /// face: the state, not the animation, decides which is readable. VoiceOver's focus goes to Turn over, since what may
    /// have been activated is on the face now hidden.
    private func turn() {
        withAnimation(CardFlip.animation(reduceMotion: reduceMotion)) { showsBack.toggle() }
        turnFocused = true
        AccessibilityNotification.Announcement(showsBack ? "Paper card" : "Patch").post()
    }
}
