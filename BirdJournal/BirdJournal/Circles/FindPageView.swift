import Album
import Pack
import SwiftUI

/// Where a find's page was opened from.
struct FindRoute: Hashable, Sendable {
    /// `FeedItem.id`: its owner and sighting.
    let itemID: String
    var surface: FindLiftSurface? = nil
    /// A led find's row has a patch to grow out of; a quiet line is a plain push.
    var liftsFromPatch = true

    var lift: FindLiftID? {
        guard liftsFromPatch else { return nil }
        return surface.map { FindLiftID(itemID: itemID, surface: $0) }
    }

    /// The Guild it was opened in; nil from the feed across Guilds.
    var openedIn: String? {
        if case .guild(let id) = surface { return id }
        return nil
    }

    /// The Guild it was opened in, for a report: where the birder saw it.
    func reportingCircle(of entry: FindEntry) -> String? {
        if case .guild(let id) = surface, entry.circleIDs.contains(id) { return id }
        return entry.circleIDs.first
    }
}

/// A friend's find, opened (issue #150, F1). Everything on it comes from the `FeedItem`, as the store has it now, so its reactions
/// stay in step with the feed: the patch in the find's edition (a blank with its tag if the phone has no painting, never another
/// edition's), who found it, how, the place the feed names, when, its marks, its reactions and a shared card's note and photo. It
/// says no more of where the bird was than the feed does: a secret spot stays one. It turns over to the paper card when the viewer's
/// pack describes the bird; without that pack it's the name and no card. Report and Block are in its menu.
struct FindPageView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(\.dismiss) private var dismiss
    let route: FindRoute
    @State private var reporting: ReportDraft?
    @State private var blocking: BlockedAccount?
    @State private var error: String?

    private var id: String { route.itemID }

    var body: some View {
        Group {
            if let entry = circles.entry(id: id, openedIn: route.openedIn) {
                FindPageContent(entry: entry, error: error)
                    .toolbar {
                        if !entry.item.isMine {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    FindMenuItems(
                                        item: entry.item,
                                        onReport: { if let circle = route.reportingCircle(of: entry) { reporting = .find(entry.item, circleID: circle) } },
                                        onBlock: { blocking = BlockedAccount(id: entry.item.owner.id, displayName: entry.item.owner.displayName) }
                                    )
                                } label: {
                                    Label("More about this find", systemImage: "ellipsis")
                                }
                                .accessibilityIdentifier("find-page-menu")
                            }
                        }
                    }
                    .navigationTitle(entry.item.isMine ? "Your find" : "\(entry.item.owner.firstName)'s find")
                    .tint(PatchEdition.tint(setID: entry.item.edition))
            } else {
                // Blocked, here or on another phone, or the Guild has gone.
                PaperPage {
                    StateNotice("This find isn't here any more", message: "You may have blocked who found it, or left the Guild.", mark: .symbol("bird"))
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        // A read of the feeds that leaves this find out (a pull underneath, a page dropped) doesn't take it off an open page.
        .onChange(of: circles.entry(id: id, openedIn: route.openedIn), initial: true) {
            circles.holdOpen(id: id, openedIn: route.openedIn)
        }
        .findSafety(reporting: $reporting, blocking: $blocking, subject: { _ in
            "\(circles.entry(id: id, openedIn: route.openedIn)?.item.owner.name ?? "this member")'s find"
        }, blocked: {
            error = $0
            if $0 == nil { dismiss() }
        })
    }
}

extension View {
    /// The report sheet and the block dialog for a find or a member, on whichever screen offered them. `blocked` gets the failure's
    /// words, or nil once it's done.
    func findSafety(reporting: Binding<ReportDraft?>, blocking: Binding<BlockedAccount?>, subject: @escaping (ReportDraft) -> String, blocked: @escaping (String?) -> Void) -> some View {
        modifier(FindSafety(reporting: reporting, blocking: blocking, subject: subject, blocked: blocked))
    }
}

private struct FindSafety: ViewModifier {
    @Environment(CircleStore.self) private var circles
    @Binding var reporting: ReportDraft?
    @Binding var blocking: BlockedAccount?
    let subject: (ReportDraft) -> String
    let blocked: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $reporting) { draft in
                ReportSheet(draft: draft, subject: subject(draft))
            }
            .confirmationDialog(
                "Block \(blocking?.name ?? "this member")?",
                isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                titleVisibility: .visible,
                presenting: blocking
            ) { account in
                Button("Block \(account.name)", role: .destructive) { block(account) }
            } message: { account in
                Text(Self.blockMessage(account.name))
            }
    }

    static func blockMessage(_ name: String) -> String {
        "You won't see \(name)'s finds or reactions, or get notifications about them, in any Guild. \(name) isn't told. Unblock in Settings → Account."
    }

    private func block(_ account: BlockedAccount) {
        Task {
            do {
                try await circles.setBlocked(true, accountID: account.id, name: account.displayName)
                blocked(nil)
            } catch {
                blocked(CircleStore.message(for: error, doing: "block \(account.name)"))
            }
        }
    }
}

private struct FindPageContent: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: FindEntry
    let error: String?
    @State private var turned = false
    @State private var opened = false
    @State private var reactionError: String?
    @AccessibilityFocusState private var turnFocused: Bool

    /// The footprint, as a patch's own page has it, a little shorter for the words under it.
    private static let footprint = CGSize(width: 330, height: 400)

    private var item: FeedItem { entry.item }
    private var reduceMotion: Bool { PatchMotion.reduces(system: systemReduceMotion) }
    /// What this phone's packs know of the bird.
    private var species: PackSpecies? { library.species(scientificName: item.scientificName)?.species }
    /// The viewer's own patch, in the find's edition.
    private var yours: CardCollection.Patch? { collectionStore.collection.patch(scientificName: item.scientificName, setID: item.edition) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                patch
                words
                if species != nil {
                    Button(action: turn) {
                        Label(turned ? "Turn back" : "Turn over", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    .buttonStyle(.journalOutlined)
                    .accessibilityValue(turned ? "Paper card" : "Patch")
                    .accessibilityHint(turned ? "Shows the patch." : "Shows its paper card, with its story.")
                    .accessibilityIdentifier("card-flip")
                    .accessibilityFocused($turnFocused)
                }
                ReactionBar(item: item) { kind, given in react(kind, given: given) }
                if let message = reactionError ?? error {
                    InlineError(message, afterAction: true).boardLabel()
                }
                if let card = item.card {
                    SharedCardExtras(card: card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                links
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, JournalLayout.margin)
            .padding(.top, 8)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .patchSheetBackground()
        .holdsPatchLight()
        .readsFriendsBirds(when: turned)
        .haptic(.turn, trigger: turned)
        .haptic(.lift, trigger: opened)
        .onAppear { opened = true }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "autoCardBack"), species != nil {
                UserDefaults.standard.removeObject(forKey: "autoCardBack")
                turned = true
            }
        }
        #endif
    }

    @ViewBuilder private var patch: some View {
        if let species {
            CollectibleCard(showsBack: turned, rotates: !reduceMotion, backGrows: typeSize.isAccessibilitySize) {
                Button(action: turn) {
                    face
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spokenPatch)
                .accessibilityHint("Turn over for its story.")
                .accessibilityIdentifier("patch-face")
            } back: {
                FriendPaperCard(species: species, edition: editionLine, setID: item.edition, isReadingView: typeSize.isAccessibilitySize)
            }
            .frame(maxWidth: Self.footprint.width)
        } else {
            face
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenPatch)
                .accessibilityIdentifier("patch-face")
        }
    }

    /// The patch centred in the footprint: a blank with its tag if the phone has no painting of it in this edition.
    private var face: some View {
        FindPatchPicture(item: item, size: .full)
            .padding(.horizontal, 22)
            .frame(maxWidth: Self.footprint.width, minHeight: typeSize.isAccessibilitySize ? 300 : Self.footprint.height)
            .contentShape(Rectangle())
    }

    private var spokenPatch: String {
        [item.commonName, editionLabel.map { "\($0) patch" } ?? "patch", item.isMine ? "yours" : "\(item.owner.name)'s"].joined(separator: ", ")
    }

    /// Who found it and how, in type below it. The same words as the feed, no more.
    private var words: some View {
        VStack(spacing: 6) {
            Text(species?.commonName ?? item.commonName)
                .font(PatchFont.pageName)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("find-page-name")
            HStack(spacing: 8) {
                MemberFace(id: item.owner.id, initials: item.owner.initials, size: 26)
                Text(FindRow.fullHeadline(item))
            }
            .font(JournalFont.supporting)
            .accessibilityElement(children: .combine)
            Text(FindRow.howAndWhere(item))
                .font(JournalFont.supporting)
                .accessibilityIdentifier("find-page-where")
            let marks = FindRow.marks(item)
            if !marks.isEmpty {
                FlowMarks(marks: marks)
                    .padding(.top, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(marks.joined(separator: ", "))
                    .accessibilityIdentifier("find-page-marks")
            }
        }
        .foregroundStyle(Color.ink)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .boardLabel(horizontal: 12, vertical: 8)
    }

    /// The way to read about the bird, and to the viewer's own patch of it. Plain buttons: they're for operating.
    private var links: some View {
        VStack(spacing: 10) {
            NavigationLink(value: Route.species(scientificName: item.scientificName, commonName: item.commonName)) {
                Text("About this bird in the Atlas")
            }
            .accessibilityIdentifier("find-page-atlas")
            if let yours {
                NavigationLink(value: Route.patch(yours.id)) {
                    Text("Your patch")
                }
                .accessibilityIdentifier("find-page-yours")
            }
        }
        .buttonStyle(.journalQuiet)
        .padding(.top, 4)
    }

    /// "Citrus edition, No. 021", when this phone knows the find's set and the bird's place in it.
    private var editionLine: String? {
        guard let set = library.cardSets.first(where: { $0.id == item.edition }) else { return nil }
        guard let number = set.number(of: item.scientificName) else { return set.edition }
        return PatchText.editionLine(.numbered(setID: set.id, setName: set.name, edition: set.edition, number: number, total: set.species.count))
    }

    /// "Citrus edition", when this phone knows the find's set.
    private var editionLabel: String? {
        library.cardSets.first { $0.id == item.edition }?.edition
    }

    /// As on a patch's own page: the state, not the animation, decides which face is readable, and VoiceOver's focus goes to Turn
    /// over, since what may have been activated is on the face now hidden.
    private func turn() {
        withAnimation(CardFlip.animation(reduceMotion: reduceMotion)) { turned.toggle() }
        turnFocused = true
        AccessibilityNotification.Announcement(turned ? "Paper card" : "Patch").post()
    }

    private func react(_ kind: ReactionKind, given: Bool) {
        Task {
            do {
                try await circles.react(kind, given: given, to: item)
                reactionError = nil
            } catch {
                reactionError = CircleStore.message(for: error, doing: "send your reaction")
            }
        }
    }
}
