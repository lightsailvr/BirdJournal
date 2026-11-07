import SwiftUI

/// A Guild's page (issue #61 as a circle's page, reskinned as a Guild in #118, a scrolling page on felt since #150): its emblem,
/// name, members and Invite, this month's goal, then Finds or Compare birds. The Info button, and the one line stating the birder's
/// sharing, open the sheet with the rest (`CircleInfoSheet`). Models, routes and endpoints keep their Circle names.
struct CirclePageView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PushCenter.self) private var pushes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let id: String
    /// On a Guild the tab opened straight onto (issue #150, G3), the way to start another, which the tab's own page would have had.
    var newGuild: (() -> Void)? = nil
    @State private var inviting = false
    @State private var showingInfo = false
    /// Report and block (issue #71).
    @State private var reporting: ReportDraft?
    @State private var blocking: BlockedAccount?
    @State private var error: String?
    @State private var showing: Showing = .finds
    @AppStorage(FindOutbox.sharingKey) private var sharesFinds = true
    /// How much of the page shows, which is the least Compare can take up: see `compareSection`.
    @State private var pageHeight: CGFloat = 0
    /// How many pages are on the Guilds tab's stack.
    @Environment(\.guildsStackDepth) private var stackDepth

    enum Showing: Hashable {
        case finds
        case compare
    }

    private var detail: CircleDetail? { circles.details[id] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                page
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, JournalLayout.margin)
                    .padding(.bottom, JournalLayout.sectionGap)
            }
            .holdsTheRowBeingRead(isOn: showing == .finds)
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in pageHeight = height }
            // The tab opened straight onto this page, or pushed it: anything more on the stack is over it.
            .keepsItsFootUnderAPage(isCovered: stackDepth > (newGuild == nil ? 1 : 0))
            #if DEBUG
            .debugScroll(proxy, to: "guild-feed", when: circles.feeds[id]?.isLoaded == true)
            #endif
        }
        .patchSheetBackground()
        .holdsPatchLight()
        .navigationTitle(detail?.circle.name ?? circles.circles.first { $0.id == id }?.name ?? "Guild")
        .navigationBarTitleDisplayMode(.inline)
        // The name is the page's own, large. The title stays as what the next page's back reads.
        .toolbar(removing: .title)
        .toolbar {
            if let newGuild {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New Guild", systemImage: "plus", action: newGuild)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Info", systemImage: "info") { showingInfo = true }
                    .tint(Color.ink)
                    .disabled(detail == nil)
                    .accessibilityIdentifier("guildInfo")
            }
        }
        // Runs again on the way back from a find, which leaves what the birder was reading where it was.
        .task { await load() }
        // A notifications explanation that never got on screen gets one more chance (issue #107).
        .task { await pushes.circlesAppeared() }
        .refreshable { await load(pulled: true) }
        .sheet(isPresented: $inviting) { InviteSheet(circleID: id, circleName: detail?.circle.name ?? "") }
        .sheet(isPresented: $showingInfo) {
            CircleInfoSheet(circleID: id) { dismiss() }
        }
        .findSafety(reporting: $reporting, blocking: $blocking, subject: subject(of:), blocked: { error = $0 })
        #if DEBUG
        .task(id: detail?.members.count) {
            guard detail != nil else { return }
            let defaults = UserDefaults.standard
            // What's reached through the sheet, for the screenshots and the tests.
            if defaults.bool(forKey: "autoCircleInfo") || defaults.bool(forKey: "autoCircleReport") || defaults.bool(forKey: "autoNewGoal") {
                defaults.removeObject(forKey: "autoCircleInfo")
                showingInfo = true
            }
        }
        .task {
            if UserDefaults.standard.bool(forKey: "autoCircleInvite") {
                UserDefaults.standard.removeObject(forKey: "autoCircleInvite")
                inviting = true
            }
        }
        #endif
    }

    @ViewBuilder private var page: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 0) {
                header(detail)
                    .padding(.top, 4)
                goal
                    .padding(.top, 20)
                links
                    .padding(.top, 6)
                Picker("Show", selection: $showing) {
                    Text("Finds").tag(Showing.finds)
                    Text("Compare birds").tag(Showing.compare)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("circlePageShowing")
                .padding(.top, 10)
                .id("guild-feed")
                switch showing {
                case .finds: finds
                case .compare: compareSection(detail)
                }
                if let error {
                    InlineError(error, afterAction: true)
                        .boardLabel()
                        .padding(.top, 12)
                }
                // The tab opened straight onto this Guild, so the tab's own way to join another is here.
                if newGuild != nil {
                    JoinWithAnInvite()
                        .padding(.top, 24)
                }
            }
        } else if let error {
            GuildsUnreachable(message: error) { Task { await load() } }
                .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 12) { GuildPlaceholder() }
                .padding(.top, 8)
        }
    }

    /// Belonging first (the mock's header): the emblem at the left, the name large, the faces and Invite under it.
    private func header(_ detail: CircleDetail) -> some View {
        AdaptiveRow(stacked: typeSize.isAccessibilitySize, spacing: 16) {
            // The emblem's ring is the page's colour, so on felt it doesn't read: the disc you see is what's the patches' size. On
            // linen the ring shows, just outside their edge.
            GuildEmblem(identity: GuildIdentity(circleID: detail.circle.id), size: 112)
                .padding(-5)
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.circle.name)
                    .font(JournalFont.title)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .accessibilityAddTraits(.isHeader)
                FacesAndInvite(detail: detail, members: circles.visibleMembers(of: detail)) { inviting = true }
            }
        }
    }

    /// The month's goal, with its patches under the thread. Without them, from an older server, the goal is thread alone.
    @ViewBuilder private var goal: some View {
        if let goals = circles.goals[id] {
            if let monthly = goals.first(where: { $0.kind == .monthly }) {
                CompactGoal(goal: monthly, circleID: id)
            }
        } else {
            GuildPlaceholder(rows: 1)
        }
    }

    /// The one line on the birder's sharing, and "All goals". Both open the sheet they live in. The line stays in view, so nobody
    /// has to go looking to see whether their finds are going out.
    private var links: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sharingLine
                Spacer(minLength: 8)
                allGoals
            }
            VStack(alignment: .leading, spacing: 0) {
                sharingLine
                allGoals
            }
        }
    }

    private var sharingLine: some View {
        Button {
            showingInfo = true
        } label: {
            Label(SharingWords.short(sharesFinds), systemImage: sharesFinds ? "person.2.wave.2" : "lock")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .boardLabel()
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.journalPress)
        .accessibilityHint("Opens this Guild's info, with the setting.")
        .accessibilityIdentifier("guildSharingLine")
    }

    private var allGoals: some View {
        Button {
            showingInfo = true
        } label: {
            HStack(spacing: 2) {
                Text("All goals")
                Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
            }
            .font(JournalFont.attribution.weight(.semibold))
            .foregroundStyle(Color.ink)
            .fixedSize()
            .boardLabel()
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.journalPress)
        .accessibilityIdentifier("guildAllGoals")
    }

    /// The Guild's finds, a page at a time.
    @ViewBuilder private var finds: some View {
        let feed = circles.feeds[id] ?? .init()
        let entries = feed.items.map { FindEntry(item: $0, circleIDs: [id]) }
        if entries.isEmpty {
            if feed.hasNoFinds {
                StateNotice("No finds yet", message: "Birds your Guild adds while sharing show here.", messageInk: .ink)
                    .boardLabel()
                    .accessibilityIdentifier("feedEmpty")
            } else if feed.isLoaded {
                // All it's read so far is someone blocked: "More finds" below reads on.
            } else if let error = feed.error {
                InlineError(error).boardLabel().padding(.top, 16)
            } else {
                VStack(alignment: .leading, spacing: 12) { GuildPlaceholder() }
                    .padding(.top, 16)
            }
        }
        FindsColumn(
            entries: entries, surface: .guild(id),
            onReport: { reporting = .find($0.item, circleID: id) },
            onBlock: { blocking = BlockedAccount(id: $0.id, displayName: $0.displayName) }
        )
        .padding(.top, 2)
        if feed.nextCursor != nil {
            MoreFinds(isLoading: feed.isLoading) { await circles.loadMoreFeed(circleID: id) }
        }
        if let error = feed.error, !entries.isEmpty {
            InlineError(error).boardLabel().padding(.top, 12)
        }
    }

    /// Compare, with room for the page to stay where it is. The picker is on screen to be tapped, so a screenful under it is all that
    /// keeps a short section from pulling the page back, and Finds come back to where they were.
    private func compareSection(_ detail: CircleDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            compare(detail)
        }
        .frame(minHeight: pageHeight, alignment: .top)
    }

    /// Compare birds: the friends in the Guild, each opening the two of you side by side. Rows to operate, so they sit on their own
    /// raised surface, not the felt.
    @ViewBuilder private func compare(_ detail: CircleDetail) -> some View {
        let friends = circles.visibleMembers(of: detail).filter { $0.id != circles.myID(in: detail) }
        VStack(alignment: .leading, spacing: 0) {
            if friends.isEmpty {
                Text("Invite a friend, then compare your birds with theirs.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(14)
            }
            ForEach(friends) { friend in
                NavigationLink(value: Route.compareBirds(friendID: friend.id, friendName: friend.name)) {
                    HStack(spacing: 12) {
                        MemberFace(member: friend, size: 36)
                        Text(friend.name).font(JournalFont.rowTitle).foregroundStyle(Color.ink)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.inkSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.journalPress)
                .accessibilityIdentifier("compareWith-\(friend.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .padding(.top, 16)
        if !friends.isEmpty {
            Text("Their patches you don't have yet, then what you both have: plan the next walk.")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .boardLabel()
                .padding(.top, 10)
        }
    }

    private func subject(of draft: ReportDraft) -> String {
        let name = detail?.members.first { $0.id == draft.accountID }?.name
            ?? circles.feeds[id]?.items.first { $0.owner.id == draft.accountID }?.owner.name
            ?? "this member"
        return draft.kind == .find ? "\(name)'s find" : name
    }

    private func load(pulled: Bool = false) async {
        do {
            try await circles.loadDetail(id: id)
            error = nil
            async let goals: Void = circles.loadGoals(circleID: id)
            if pulled || circles.isFeedStale(id) { await circles.loadFeed(circleID: id) }
            await goals
        } catch {
            self.error = CircleStore.message(for: error, doing: "load the Guild")
        }
    }
}

/// Who's in the Guild, in faces VoiceOver reads as a sentence, and Invite.
private struct FacesAndInvite: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let detail: CircleDetail
    /// Those not blocked.
    let members: [CircleMember]
    let invite: () -> Void

    /// Everyone in the Guild but the blocked, some of whom the page may not have read yet.
    private var total: Int { detail.circle.memberCount - (detail.members.count - members.count) }

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows, spacing: 12) {
            MemberFaces(members: members, total: total, shown: 5)
                .accessibilityHidden(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
            Button(action: invite) {
                Text("Invite")
            }
            .buttonStyle(InvitePillStyle())
            .disabled(detail.circle.memberCount >= 20)
            .accessibilityLabel("Invite friends")
            .accessibilityValue(detail.circle.memberCount >= 20 ? "This Guild is full" : "")
        }
    }

    /// "4 members, invite-only: Pat Birder, Maya Ortiz, Jo Park and Sam Okafor".
    private var spoken: String {
        "\(total == 1 ? "1 member" : "\(total) members"), invite-only: \(members.map(\.name).formatted(.list(type: .and)))"
    }
}

/// Invite, as the mock draws it: a small outlined pill, no taller than the faces beside it, answering to 44 pt.
private struct InvitePillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: JournalLayout.outlineRadius(typeSize), style: .continuous)
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.ink.opacity(configuration.isPressed ? 0.15 : 0), in: shape)
            .overlay(shape.strokeBorder(Color.ink, lineWidth: 1))
            .frame(minHeight: 44)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect)
            .pressResponse(isPressed: configuration.isPressed)
    }
}

/// Another page of finds. Quiet, and not on a list row: it asks for more of what it sits under.
struct MoreFinds: View {
    let isLoading: Bool
    let load: () async -> Void

    var body: some View {
        Button {
            Task { await load() }
        } label: {
            if isLoading { ProgressView() } else { Text("More finds") }
        }
        .buttonStyle(.journalQuiet)
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .accessibilityIdentifier("feedMore")
    }
}

/// What "Share my finds automatically" means, in one line and in full: the same words wherever the setting is.
enum SharingWords {
    static func line(_ sharing: Bool) -> String {
        sharing ? "Birds you add reach your Guilds, never with the exact spot." : "You're private: birds you add stay on this iPhone."
    }

    /// The one line on a Guild's page, which opens the setting.
    static func short(_ sharing: Bool) -> String {
        sharing ? "Sharing your finds automatically" : "You're private: finds stay here"
    }

    static func detail(_ sharing: Bool) -> String {
        sharing
            ? "Birds you add while signed in reach your Guilds as finds: the bird, Heard or Seen, the city and the time. Notes and original photos stay on this iPhone unless you share a patch with them. Threatened birds show as at a secret spot."
            : "Share a patch by hand to show it in a Guild. Finds you already shared stay in your Guilds until you remove the sighting."
    }
}

/// Makes an invitation and shows it as a QR code and a link to share. The QR code encodes the link itself.
struct InviteSheet: View {
    @Environment(CircleStore.self) private var circles
    @Environment(\.dismiss) private var dismiss
    let circleID: String
    let circleName: String
    @State private var invite: CircleInvite?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let invite {
                        Text("Scan to join \(circleName)")
                            .font(JournalFont.heading)
                            .multilineTextAlignment(.center)
                        if let image = InviteQRCode.image(for: invite.url) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 240, height: 240)
                                .padding(16)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius))
                                .accessibilityLabel("QR code for the invitation link")
                                .accessibilityValue(invite.url.absoluteString)
                                .accessibilityIdentifier("inviteQRCode")
                        }
                        ShareLink(item: invite.url, subject: Text("Join \(circleName) on Featherguild"), message: Text("Join my Guild \(circleName) on Featherguild")) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.journalPrimary)
                        Button {
                            UIPasteboard.general.url = invite.url
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                        }
                        .buttonStyle(.journalOutlined)
                        .accessibilityIdentifier("inviteCopyLink")
                        Text("Expires \(invite.expiresAt.formatted(date: .abbreviated, time: .shortened)). Anyone with the link can join until then, up to 20 members.")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .multilineTextAlignment(.center)
                    } else if let error {
                        Text(error).foregroundStyle(Color.inkSecondary)
                        Button("Try again") { Task { await make() } }
                    } else {
                        ProgressView("Making an invitation…")
                    }
                }
                .padding(JournalLayout.margin)
                .frame(maxWidth: .infinity)
            }
            .background(Color.paper)
            .navigationTitle("Invite friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { if invite == nil { await make() } }
        }
    }

    private func make() async {
        error = nil
        do {
            invite = try await circles.invite(circleID: circleID)
        } catch {
            self.error = CircleStore.message(for: error, doing: "make an invitation")
        }
    }
}
