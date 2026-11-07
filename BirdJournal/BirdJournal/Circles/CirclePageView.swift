import SwiftUI

/// A Guild's page (issue #61 as a circle's page, reskinned as a Guild in #118, a scrolling page on felt since #150): its emblem,
/// name, members and Invite, this month's goal, then Finds or Compare birds. The Info button, and the one line stating the birder's
/// sharing, open the sheet with the rest (`CircleInfoSheet`). Models, routes and endpoints keep their Circle names.
struct CirclePageView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PushCenter.self) private var pushes
    @Environment(\.dismiss) private var dismiss
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
    /// Back from a find's page isn't a new visit: reading the first page again would throw away the pages under it.
    @State private var hasLoaded = false
    @AppStorage(FindOutbox.sharingKey) private var sharesFinds = true

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
                    .disabled(detail == nil)
                    .accessibilityIdentifier("guildInfo")
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        // A notifications explanation that never got on screen gets one more chance (issue #107).
        .task { await pushes.circlesAppeared() }
        .refreshable { await load() }
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
                .controlSize(.large)
                .accessibilityIdentifier("circlePageShowing")
                .padding(.top, 10)
                .id("guild-feed")
                switch showing {
                case .finds: finds
                case .compare: compare(detail)
                }
                if let error {
                    InlineError(error, afterAction: true)
                        .boardLabel()
                        .padding(.top, 12)
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
        HeaderLayout {
            GuildEmblem(identity: GuildIdentity(circleID: detail.circle.id), size: 102)
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.circle.name)
                    .font(JournalFont.largeTitle)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .accessibilityAddTraits(.isHeader)
                FacesAndInvite(detail: detail) { inviting = true }
            }
        }
    }

    /// The month's goal, with a place for its patches (slice 8) under the thread. Without them the goal is thread alone.
    @ViewBuilder private var goal: some View {
        if let goals = circles.goals[id] {
            if let monthly = goals.first(where: { $0.kind == .monthly }) {
                CompactGoal(goal: monthly)
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
            if feed.isLoaded {
                StateNotice("No finds yet", message: "Birds your Guild adds while sharing show here.", messageInk: .ink)
                    .boardLabel()
                    .accessibilityIdentifier("feedEmpty")
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

    /// Compare birds: the friends in the Guild, each opening the two of you side by side. Rows to operate, so they sit on their own
    /// raised surface, not the felt.
    @ViewBuilder private func compare(_ detail: CircleDetail) -> some View {
        let friends = detail.members.filter { $0.id != myID(in: detail) }
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
            Text("Each species Heard, Seen or not yet, for you and a friend: plan the next walk.")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .boardLabel()
                .padding(.top, 10)
        }
    }

    static func blockMessage(_ name: String) -> String {
        "You won't see \(name)'s finds or reactions, or get notifications about them, in any Guild. \(name) isn't told. Unblock in Settings → Account."
    }

    private func subject(of draft: ReportDraft) -> String {
        let name = detail?.members.first { $0.id == draft.accountID }?.name
            ?? circles.feeds[id]?.items.first { $0.owner.id == draft.accountID }?.owner.name
            ?? "this member"
        return draft.kind == .find ? "\(name)'s find" : name
    }

    /// The signed-in birder among the members: the account's ID, or until the account is read (it may not be, on a cached page
    /// with no connection), the sign-in's, or the creator's if the birder created the circle.
    private func myID(in detail: CircleDetail) -> String? {
        circles.account.account?.id ?? circles.account.identity.subject ?? (detail.circle.isCreator ? detail.circle.createdBy : nil)
    }

    private func load() async {
        do {
            try await circles.loadDetail(id: id)
            error = nil
            async let goals: Void = circles.loadGoals(circleID: id)
            await circles.loadFeed(circleID: id)
            await goals
        } catch {
            self.error = CircleStore.message(for: error, doing: "load the Guild")
        }
    }
}

/// The emblem beside the name and faces, stacked at the largest text sizes.
private struct HeaderLayout<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: Content

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout { content }
    }
}

/// Who's in the Guild, in faces VoiceOver reads as a sentence, and Invite.
private struct FacesAndInvite: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let detail: CircleDetail
    let invite: () -> Void

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows, spacing: 12) {
            MemberFaces(members: detail.members, total: detail.circle.memberCount, shown: 5)
                .accessibilityHidden(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(detail))
            Button(action: invite) {
                Text("Invite")
            }
            .buttonStyle(.journalQuiet)
            .disabled(detail.circle.memberCount >= 20)
            .accessibilityLabel("Invite friends")
            .accessibilityValue(detail.circle.memberCount >= 20 ? "This Guild is full" : "")
        }
    }

    /// "4 members, invite-only: Pat Birder, Maya Ortiz, Jo Park and Sam Okafor".
    static func spoken(_ detail: CircleDetail) -> String {
        let members = detail.circle.memberCount == 1 ? "1 member" : "\(detail.circle.memberCount) members"
        return "\(members), invite-only: \(detail.members.map(\.name).formatted(.list(type: .and)))"
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
