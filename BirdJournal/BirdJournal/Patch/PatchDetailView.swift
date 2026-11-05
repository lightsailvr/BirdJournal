import Album
import Pack
import SwiftData
import SwiftUI

/// One patch at a time, swiping left or right through every patch you have (issue #134, `CardCollection.browsingOrder`).
/// A swipe always lands on the next patch's face, even from a paper card. Opening a patch shows the patch.
struct PatchDetailView: View {
    @Environment(PackLibrary.self) private var library
    @Query(Sighting.newestFirst()) private var allSightings: [Sighting]
    /// The patch showing: the one opened, until a swipe.
    @State private var current: CardCollection.Patch.Key
    /// The one patch turned over to its card, if any: state here, so a swipe can put it back.
    @State private var turned: CardCollection.Patch.Key?
    @State private var isSharing = false

    init(key: CardCollection.Patch.Key) {
        _current = State(initialValue: key)
    }

    var body: some View {
        let order = library.collection(of: allSightings).browsingOrder
        if let index = order.firstIndex(where: { $0.id == current }) {
            TabView(selection: $current) {
                ForEach(order) { patch in
                    PatchPage(
                        patch: patch, sightings: patch.ownSightings(among: allSightings),
                        showsCard: Binding(get: { turned == patch.id }, set: { turned = $0 ? patch.id : nil }),
                        previous: index > 0 ? { go(to: order[index - 1].id) } : nil,
                        next: index + 1 < order.count ? { go(to: order[index + 1].id) } : nil
                    )
                    .tag(patch.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: current) { turned = nil }
            .patchSheetBackground()
            .holdsPatchLight()
            .navigationTitle("\(index + 1) of \(order.count)")
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
            .sensoryFeedback(.impact(weight: .light), trigger: turned)
            .sheet(isPresented: $isSharing) {
                if let latest = order[index].ownSightings(among: allSightings).first {
                    ShareCardView(sighting: latest)
                }
            }
            .task {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "autoCardBack") {
                    UserDefaults.standard.removeObject(forKey: "autoCardBack")
                    turned = current
                }
                #endif
            }
        } else {
            // The last sighting was removed from under the page.
            ContentUnavailableView("Patch unpicked", systemImage: "bird", description: Text("Its last sighting here was removed."))
                .background(Color.paper)
        }
    }

    private func go(to key: CardCollection.Patch.Key) {
        withAnimation { current = key }
    }
}

/// One patch's page (guide page 6). Upright: the patch large on felt, with its name, edition and count set in type below it,
/// and tapping it or the visible Turn over flips the object to its paper card. On its side there's room for both: the patch
/// on the left and its card on the right, scrolling, so nothing turns. The face hosts no controls beyond the turn:
/// sightings, notes, photos and sources open from the card.
private struct PatchPage: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let patch: CardCollection.Patch
    /// Its sightings, newest first.
    let sightings: [Sighting]
    @Binding var showsCard: Bool
    let previous: (() -> Void)?
    let next: (() -> Void)?
    @AccessibilityFocusState private var turnFocused: Bool

    /// The footprint at default text size (guide page 10), on a phone wide enough for it.
    private static let footprint = CGSize(width: 330, height: 470)

    private var reduceMotion: Bool { PatchMotion.reduces(system: systemReduceMotion) }
    private var name: String { PatchText.name(of: patch, library: library) }
    private var isSideways: Bool { verticalSizeClass == .compact }

    var body: some View {
        if isSideways {
            sideBySide
        } else {
            upright
        }
    }

    private var sideBySide: some View {
        HStack(spacing: 16) {
            VStack(spacing: 6) {
                picture
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PatchText.spoken(patch, name: name))
                    .accessibilityIdentifier("patch-face")
                words
            }
            .frame(maxWidth: .infinity)
            PaperCardView(patch: patch, sightings: sightings, name: name, isReadingView: false)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var upright: some View {
        ScrollView {
            VStack(spacing: 16) {
                CollectibleCard(showsBack: showsCard, rotates: !reduceMotion, backGrows: typeSize.isAccessibilitySize) {
                    face
                } back: {
                    PaperCardView(patch: patch, sightings: sightings, name: name, isReadingView: typeSize.isAccessibilitySize)
                }
                .frame(maxWidth: Self.footprint.width)
                if showsCard {
                    Text("Your notes, photos and every sighting open from this side.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    words
                }
                Button(action: turn) {
                    Label(showsCard ? "Turn back" : "Turn over", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .buttonStyle(.journalOutlined)
                .accessibilityValue(showsCard ? "Paper card" : "Patch")
                .accessibilityHint(showsCard ? "Shows the patch." : "Shows its paper card, with its story and your sightings.")
                .accessibilityIdentifier("card-flip")
                .accessibilityFocused($turnFocused)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, JournalLayout.sectionGap)
        }
    }

    private var picture: some View {
        PatchView(
            art: library.patchArt(scientificName: patch.scientificName, setID: patch.placement.setID),
            edition: PatchEdition.of(setID: patch.placement.setID), size: .full, tag: name
        )
    }

    /// The front: the patch centred in the footprint. Tapping it turns it.
    private var face: some View {
        Button(action: turn) {
            picture
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 300 : Self.footprint.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PatchText.spoken(patch, name: name))
        .accessibilityHint("Turn over for its story.")
        .accessibilityIdentifier("patch-face")
        .accessibilityActions {
            if let previous { Button("Previous patch", action: previous) }
            if let next { Button("Next patch", action: next) }
        }
    }

    /// The patch's words, set in type below it.
    private var words: some View {
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

    /// Turns the object over and says which face is up. A tap during a turn retargets it, so rapid taps settle on one
    /// face: the state, not the animation, decides which is readable. VoiceOver's focus goes to Turn over, since what may
    /// have been activated is on the face now hidden.
    private func turn() {
        withAnimation(CardFlip.animation(reduceMotion: reduceMotion)) { showsCard.toggle() }
        turnFocused = true
        AccessibilityNotification.Announcement(showsCard ? "Paper card" : "Patch").post()
    }
}
