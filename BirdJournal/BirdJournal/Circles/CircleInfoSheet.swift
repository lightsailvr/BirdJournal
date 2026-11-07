import SwiftUI

/// A Guild's administration (issue #150, G2), out of the way of its finds: a native list with its goals, the birder's own sharing,
/// the members with their swipes and context menus, notifications, mute and Leave. Felt is for runs of objects, never for lists of
/// controls.
struct CircleInfoSheet: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PushCenter.self) private var pushes
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let circleID: String
    /// The birder left: the sheet closes and the page goes with it.
    let left: () -> Void
    @State private var editing = false
    @State private var confirmingLeave = false
    @State private var removing: CircleMember?
    @State private var reporting: ReportDraft?
    @State private var blocking: BlockedAccount?
    @State private var error: String?
    @AppStorage(FindOutbox.sharingKey) private var sharesFinds = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                PaperList {
                    if let detail = circles.details[circleID] {
                        if let error {
                            Section { InlineError(error, afterAction: true) }
                        }
                        if detail.circle.isCreator {
                            Section {
                                Button("Edit Guild", systemImage: "pencil") { editing = true }
                                    .accessibilityIdentifier("editGuild")
                            }
                        }
                        CircleGoalsSection(circleID: circleID, timeZone: detail.circle.timeZone)
                        sharing
                        members(detail)
                        settings(detail)
                    }
                }
                #if DEBUG
                .debugScroll(proxy, to: "guild-settings")
                #endif
            }
            .navigationTitle(circles.details[circleID]?.circle.name ?? "Guild")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(isPresented: $editing) {
            if let circle = circles.details[circleID]?.circle { GuildEditorSheet(circle: circle) }
        }
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
        .findSafety(reporting: $reporting, blocking: $blocking, subject: { draft in
            circles.details[circleID]?.members.first { $0.id == draft.accountID }?.name ?? "this member"
        }, blocked: { error = $0 })
        #if DEBUG
        .task {
            // Issue #71's screenshot: the report sheet for the first friend.
            if UserDefaults.standard.bool(forKey: "autoCircleReport"), let detail = circles.details[circleID],
               let friend = detail.members.first(where: { $0.id != circles.myID(in: detail) }) {
                UserDefaults.standard.removeObject(forKey: "autoCircleReport")
                reporting = .account(friend, circleID: circleID)
            }
        }
        #endif
    }

    /// The birder's own sharing (design guide page 13): the same setting as Settings → Account.
    private var sharing: some View {
        Section {
            Toggle(isOn: $sharesFinds) {
                Label("Share my finds automatically", systemImage: sharesFinds ? "person.2.wave.2" : "lock")
            }
            .accessibilityIdentifier("guildShareFindsToggle")
            HowThisWorks(SharingWords.detail(sharesFinds))
        } header: {
            Text("Your sharing")
        } footer: {
            Text(SharingWords.line(sharesFinds))
        }
    }

    private func members(_ detail: CircleDetail) -> some View {
        Section {
            ForEach(detail.members) { member in
                let isMe = member.id == circles.myID(in: detail)
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
                                reporting = .account(member, circleID: circleID)
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
            Text("Members, \(detail.members.count) of 20")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if detail.members.count > 1 {
                    Text(detail.circle.isCreator
                         ? "You started this Guild: swipe a member to mute or remove them. Touch and hold to report or block."
                         : "Swipe a friend to mute their finds' notifications. Touch and hold to report or block.")
                }
                Text(detail.circle.memberCount >= 20
                     ? "This Guild is full: a Guild holds 20 birders."
                     : "Anyone in the Guild can invite. Invitations last seven days.")
            }
        }
    }

    private func settings(_ detail: CircleDetail) -> some View {
        Section {
            if pushes.isAvailable {
                notifications
            }
            Button("Leave Guild", role: .destructive) { confirmingLeave = true }
                .foregroundStyle(Color.alert)
                .id("guild-settings")
        } header: {
            Text("Settings")
        } footer: {
            if pushes.isAvailable, pushes.permission == .denied {
                Text("Notifications are off for Featherguild, so friends' finds arrive only in the feed. Turn them on in Settings → Notifications.")
            } else if circles.mutes.circles.contains(circleID) {
                Text("Muted: this Guild's finds still show here, without notifications.")
            }
        }
    }

    /// Mute, and the way back to notifications when they are off (issue #63).
    @ViewBuilder
    private var notifications: some View {
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
            get: { circles.mutes.circles.contains(circleID) },
            set: { muted in setCircleMuted(muted) }
        )) {
            Label("Mute this Guild", systemImage: "bell.slash")
        }
    }

    private func setCircleMuted(_ muted: Bool) {
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
        if let detail = circles.details[circleID], detail.circle.isCreator, detail.members.count > 1 {
            return "You started this Guild. It passes to the member who has been in it longest."
        }
        return "You can join again only with a new invitation."
    }

    private func leave() {
        Task {
            do {
                try await circles.leave(circleID: circleID)
                dismiss()
                left()
            } catch {
                self.error = CircleStore.message(for: error, doing: "leave the Guild")
            }
        }
    }

    private func remove(_ member: CircleMember) {
        Task {
            do {
                try await circles.remove(memberID: member.id, circleID: circleID)
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
            MemberFace(member: member, size: 36)
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
