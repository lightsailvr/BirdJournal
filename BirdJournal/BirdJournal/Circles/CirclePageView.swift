import SwiftUI

/// A Guild's page (issue #61 as a circle's page, reskinned as a Guild in #118): its habitat cover, emblem and members
/// with the Invite action first, then the shared goals (issue #65), Finds (issue #62) or Compare birds (issue #64), the
/// birder's own sharing setting kept in view, and, after them, the members and the settings (leave; the creator removes
/// members). Models, routes and endpoints keep their Circle names.
struct CirclePageView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PushCenter.self) private var pushes
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let id: String
    @State private var inviting = false
    @State private var confirmingLeave = false
    @State private var removing: CircleMember?
    /// Report and block (issue #71).
    @State private var reporting: ReportDraft?
    @State private var blocking: BlockedAccount?
    @State private var error: String?
    @State private var showing: Showing = .finds
    @AppStorage(FindOutbox.sharingKey) private var sharesFinds = true

    enum Showing: Hashable {
        case finds
        case compare
    }

    private var detail: CircleDetail? { circles.details[id] }

    var body: some View {
        ScrollViewReader { proxy in
            page
                #if DEBUG
                .debugScroll(proxy, to: "guild-feed", when: circles.feeds[id]?.isLoaded == true)
                .debugScroll(proxy, to: "guild-settings", when: circles.feeds[id]?.isLoaded == true)
                #endif
        }
    }

    private var page: some View {
        List {
            if let detail {
                header(detail)
                CircleGoalsSection(circleID: detail.circle.id, timeZone: detail.circle.timeZone)
                Section {
                    Picker("Show", selection: $showing) {
                        Text("Finds").tag(Showing.finds)
                        Text("Compare birds").tag(Showing.compare)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("circlePageShowing")
                    .id("guild-feed")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                switch showing {
                case .finds:
                    CircleFeedSection(
                        circleID: detail.circle.id,
                        onReport: { item in reporting = .find(item, circleID: detail.circle.id) },
                        onBlock: { owner in blocking = BlockedAccount(id: owner.id, displayName: owner.displayName) }
                    )
                case .compare: compare(detail)
                }
                sharing
                members(detail)
                settings(detail)
            } else if let error {
                Section {
                    GuildsUnreachable(message: error) { Task { await load() } }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
            if let error, detail != nil {
                Section { InlineError(error) }
            }
        }
        .paperList()
        .navigationTitle(detail?.circle.name ?? circles.circles.first { $0.id == id }?.name ?? "Guild")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // A notifications explanation that never got on screen gets one more chance (issue #107).
        .task { await pushes.circlesAppeared() }
        .refreshable { await load() }
        .sheet(isPresented: $inviting) { InviteSheet(circleID: id, circleName: detail?.circle.name ?? "") }
        .confirmationDialog("Leave this Guild?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave Guild", role: .destructive) { leave() }
        } message: {
            Text(leaveMessage)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this member")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { member in
            Button("Remove from Guild", role: .destructive) { remove(member) }
        } message: { _ in
            Text("They can come back only with a new invitation.")
        }
        .sheet(item: $reporting) { draft in
            ReportSheet(draft: draft, subject: subject(of: draft))
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
        #if DEBUG
        .task(id: detail?.members.count) {
            // Issue #71's screenshot: the report sheet for the first friend.
            if UserDefaults.standard.bool(forKey: "autoCircleReport"), let detail,
               let friend = detail.members.first(where: { $0.id != myID(in: detail) }) {
                UserDefaults.standard.removeObject(forKey: "autoCircleReport")
                reporting = .account(friend, circleID: detail.circle.id)
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

    /// Compare birds: the friends in the Guild, each opening the two of you side by side.
    private func compare(_ detail: CircleDetail) -> some View {
        let friends = detail.members.filter { $0.id != myID(in: detail) }
        return Section {
            if friends.isEmpty {
                Text("Invite a friend, then compare your birds with theirs.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
            ForEach(friends) { friend in
                NavigationLink(value: Route.compareBirds(friendID: friend.id, friendName: friend.name)) {
                    MemberRow(member: friend, isMe: false)
                }
                .accessibilityIdentifier("compareWith-\(friend.id)")
            }
        } header: {
            Text("Compare birds")
        } footer: {
            if !friends.isEmpty {
                Text("Each species Heard, Seen or not yet, for you and a friend: plan the next walk.")
            }
        }
        .listRowBackground(Color.raised)
    }

    /// Belonging first: the habitat cover, the emblem and name, who is in it, and Invite.
    private func header(_ detail: CircleDetail) -> some View {
        let identity = GuildIdentity(circleID: detail.circle.id)
        let full = detail.circle.memberCount >= 20
        return Section {
            VStack(alignment: .leading, spacing: 0) {
                GuildCover(identity: identity)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                HStack(alignment: .top, spacing: 14) {
                    GuildEmblem(identity: identity, size: 72)
                        .padding(.top, -36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.circle.name)
                            .font(JournalFont.title)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(detail.circle.memberCount == 1 ? "1 member" : "\(detail.circle.memberCount) members") · Invite-only")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            // Wraps at the largest sizes instead of "4 members…" (issue #119).
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 6)
                AdaptiveRow(stacked: typeSize.stacksRows) {
                    MemberFaces(members: detail.members, total: detail.circle.memberCount, shown: 5)
                    if !typeSize.stacksRows { Spacer(minLength: 10) }
                    Button {
                        inviting = true
                    } label: {
                        Label("Invite friends", systemImage: "qrcode")
                    }
                    .buttonStyle(.journalOutlined)
                    .disabled(full)
                }
                .padding(.top, 10)
                .padding(.horizontal, 6)
                Text(full
                     ? "This Guild is full: a Guild holds 20 birders."
                     : "Anyone in the Guild can invite. Invitations last seven days.")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
        }
    }

    /// The birder's own sharing, in view on every Guild (design guide page 13): the same setting as Settings → Account.
    private var sharing: some View {
        Section {
            Toggle(isOn: $sharesFinds) {
                Label("Share my finds automatically", systemImage: sharesFinds ? "person.2.wave.2" : "lock")
            }
            .tint(Color.moss)
            .accessibilityIdentifier("guildShareFindsToggle")
        } header: {
            Text("Your sharing")
        } footer: {
            Text(sharesFinds
                 ? "Birds you add reach your Guilds as finds: the bird, Heard or Seen, the city and the time, never the exact spot. Notes and original photos stay on this iPhone unless you share a card with them. Threatened birds show as at a secret spot."
                 : "You're private: birds you add stay on this iPhone. Share a card by hand to show it here.")
        }
        .listRowBackground(Color.raised)
    }

    private func members(_ detail: CircleDetail) -> some View {
        Section {
            ForEach(detail.members) { member in
                let isMe = member.id == myID(in: detail)
                let isMuted = circles.mutes.friends.contains(member.id)
                let isBlocked = circles.blocked.contains { $0.id == member.id }
                MemberRow(member: member, isMe: isMe, isMuted: isMuted, isBlocked: isBlocked)
                    .swipeActions {
                        if detail.circle.isCreator, !isMe {
                            Button("Remove", role: .destructive) { removing = member }
                        }
                        if !isMe {
                            Button(isMuted ? "Unmute" : "Mute") { setFriendMuted(!isMuted, member) }
                                .tint(Color.inkSecondary)
                        }
                    }
                    .contextMenu {
                        if !isMe {
                            Button(isMuted ? "Unmute \(member.name)" : "Mute \(member.name)", systemImage: isMuted ? "bell" : "bell.slash") {
                                setFriendMuted(!isMuted, member)
                            }
                            Button("Report \(member.name)…", systemImage: "exclamationmark.bubble") {
                                reporting = .account(member, circleID: detail.circle.id)
                            }
                            if isBlocked {
                                Button("Unblock \(member.name)", systemImage: "hand.raised.slash") {
                                    unblock(BlockedAccount(id: member.id, displayName: member.displayName))
                                }
                            } else {
                                Button("Block \(member.name)…", systemImage: "hand.raised", role: .destructive) {
                                    blocking = BlockedAccount(id: member.id, displayName: member.displayName)
                                }
                            }
                        }
                        if detail.circle.isCreator, !isMe {
                            Button("Remove from Guild", systemImage: "person.badge.minus", role: .destructive) { removing = member }
                        }
                    }
            }
        } header: {
            Text("Members · \(detail.members.count) of 20")
        } footer: {
            if detail.members.count > 1 {
                Text(detail.circle.isCreator
                     ? "You started this Guild: swipe a member to mute or remove them. Touch and hold to report or block."
                     : "Swipe a friend to mute their finds' notifications. Touch and hold to report or block.")
            }
        }
        .listRowBackground(Color.raised)
    }

    private func settings(_ detail: CircleDetail) -> some View {
        Section {
            if pushes.isAvailable {
                notifications(detail)
            }
            Button("Leave Guild", role: .destructive) { confirmingLeave = true }
                .foregroundStyle(Color.alert)
                .id("guild-settings")
        } header: {
            Text("Settings")
        } footer: {
            if pushes.isAvailable, pushes.permission == .denied {
                Text("Notifications are off for Featherguild, so friends' finds arrive only in the feed. Turn them on in Settings → Notifications.")
            } else if circles.mutes.circles.contains(detail.circle.id) {
                Text("Muted: this Guild's finds still show here, without notifications.")
            }
        }
        .listRowBackground(Color.raised)
    }

    /// Mute, and the way back to notifications when they are off (issue #63).
    @ViewBuilder
    private func notifications(_ detail: CircleDetail) -> some View {
        switch pushes.permission {
        case .denied:
            Button("Open notification settings", systemImage: "bell.badge") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
        case .notDetermined:
            Button("Turn on notifications", systemImage: "bell.badge") { Task { await pushes.turnOn() } }
        default:
            EmptyView()
        }
        Toggle(isOn: Binding(
            get: { circles.mutes.circles.contains(detail.circle.id) },
            set: { muted in setCircleMuted(muted, detail.circle.id) }
        )) {
            Label("Mute this Guild", systemImage: "bell.slash")
        }
        .tint(Color.moss)
    }

    private func setCircleMuted(_ muted: Bool, _ circleID: String) {
        Task {
            do {
                try await circles.setCircleMuted(muted, circleID: circleID)
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: muted ? "mute the Guild" : "unmute the Guild")
            }
        }
    }

    private func setFriendMuted(_ muted: Bool, _ member: CircleMember) {
        Task {
            do {
                try await circles.setFriendMuted(muted, friendID: member.id)
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: muted ? "mute \(member.name)" : "unmute \(member.name)")
            }
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

    private func block(_ account: BlockedAccount) {
        Task {
            do {
                try await circles.setBlocked(true, accountID: account.id, name: account.displayName)
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: "block \(account.name)")
            }
        }
    }

    private func unblock(_ account: BlockedAccount) {
        Task {
            do {
                try await circles.setBlocked(false, accountID: account.id, name: account.displayName)
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: "unblock \(account.name)")
            }
        }
    }

    private var leaveMessage: String {
        guard let detail else { return "" }
        if detail.circle.isCreator, detail.members.count > 1 {
            return "You started this Guild. It passes to the member who has been in it longest."
        }
        return "You can join again only with a new invitation."
    }

    /// The signed-in birder among the members: the account's ID, or the creator's when the account isn't read yet
    /// and the birder created the circle.
    private func myID(in detail: CircleDetail) -> String? {
        circles.account.account?.id ?? (detail.circle.isCreator ? detail.circle.createdBy : nil)
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

    private func leave() {
        Task {
            do {
                try await circles.leave(circleID: id)
                dismiss()
            } catch {
                self.error = CircleStore.message(for: error, doing: "leave the Guild")
            }
        }
    }

    private func remove(_ member: CircleMember) {
        Task {
            do {
                try await circles.remove(memberID: member.id, circleID: id)
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: "remove \(member.name)")
            }
        }
    }
}

private struct MemberRow: View {
    let member: CircleMember
    let isMe: Bool
    var isMuted = false
    var isBlocked = false

    var body: some View {
        HStack(spacing: 12) {
            Text(member.initials)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.mossText)
                .frame(width: 36, height: 36)
                .background(Color.moss, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(member.name) (you)" : member.name).font(JournalFont.rowTitle)
                if member.isCreator {
                    Text("Started the Guild").font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
                }
            }
            if isMuted || isBlocked {
                Spacer()
            }
            if isBlocked {
                Image(systemName: "hand.raised")
                    .foregroundStyle(Color.inkSecondary)
                    .accessibilityLabel("Blocked")
            } else if isMuted {
                Image(systemName: "bell.slash")
                    .foregroundStyle(Color.inkSecondary)
                    .accessibilityLabel("Muted")
            }
        }
        .accessibilityElement(children: .combine)
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
                        Text(invite.url.absoluteString)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Color.inkSecondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                        ShareLink(item: invite.url, subject: Text("Join \(circleName) on Featherguild"), message: Text("Join my Guild \(circleName) on Featherguild")) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.journalPrimary)
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
