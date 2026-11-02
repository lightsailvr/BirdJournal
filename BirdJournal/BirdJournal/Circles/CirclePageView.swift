import SwiftUI

/// A circle's page (issue #61), the shell later tickets fill with the goal card: Recent finds (issue #62), invite (a
/// link and a QR code), the members, and the settings (leave; the creator removes members).
struct CirclePageView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PushCenter.self) private var pushes
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var inviting = false
    @State private var confirmingLeave = false
    @State private var removing: CircleMember?
    @State private var error: String?

    private var detail: CircleDetail? { circles.details[id] }

    var body: some View {
        List {
            if let detail {
                CircleFeedSection(circleID: detail.circle.id)
                header(detail)
                members(detail)
                settings(detail)
            } else if let error {
                Section { Text(error).foregroundStyle(Color.inkSecondary) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
            if let error, detail != nil {
                Section { Text(error).foregroundStyle(.red).font(JournalFont.supporting) }
            }
        }
        .paperList()
        .navigationTitle(detail?.circle.name ?? circles.circles.first { $0.id == id }?.name ?? "Circle")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $inviting) { InviteSheet(circleID: id, circleName: detail?.circle.name ?? "") }
        .confirmationDialog("Leave this circle?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave circle", role: .destructive) { leave() }
        } message: {
            Text(leaveMessage)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this member")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { member in
            Button("Remove from circle", role: .destructive) { remove(member) }
        } message: { _ in
            Text("They can come back only with a new invitation.")
        }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "autoCircleInvite") {
                UserDefaults.standard.removeObject(forKey: "autoCircleInvite")
                inviting = true
            }
        }
        #endif
    }

    private func header(_ detail: CircleDetail) -> some View {
        Section {
            Button {
                inviting = true
            } label: {
                Label("Invite friends", systemImage: "qrcode")
            }
            .buttonStyle(.journalPrimary)
            .disabled(detail.circle.memberCount >= 20)
            .listRowBackground(Color.clear)
        } footer: {
            Text(detail.circle.memberCount >= 20
                 ? "This circle is full: a circle holds 20 birders."
                 : "Anyone in the circle can invite. Invitations last seven days.")
        }
    }

    private func members(_ detail: CircleDetail) -> some View {
        Section {
            ForEach(detail.members) { member in
                let isMe = member.id == myID(in: detail)
                let isMuted = circles.mutes.friends.contains(member.id)
                MemberRow(member: member, isMe: isMe, isMuted: isMuted)
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
                        }
                        if detail.circle.isCreator, !isMe {
                            Button("Remove from circle", systemImage: "person.badge.minus", role: .destructive) { removing = member }
                        }
                    }
            }
        } header: {
            Text("Members · \(detail.members.count) of 20")
        } footer: {
            if detail.members.count > 1 {
                Text(detail.circle.isCreator
                     ? "You started this circle: swipe a member to mute or remove them."
                     : "Swipe a friend to mute their finds' notifications.")
            }
        }
    }

    private func settings(_ detail: CircleDetail) -> some View {
        Section {
            if pushes.isAvailable {
                notifications(detail)
            }
            Button("Leave circle", role: .destructive) { confirmingLeave = true }
        } header: {
            Text("Settings")
        } footer: {
            if pushes.isAvailable, pushes.permission == .denied {
                Text("Notifications are off for Bird Journal, so friends' finds arrive only in the feed. Turn them on in Settings → Notifications.")
            } else if circles.mutes.circles.contains(detail.circle.id) {
                Text("Muted: this circle's finds still show here, without notifications.")
            }
        }
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
            Label("Mute this circle", systemImage: "bell.slash")
        }
        .tint(Color.moss)
    }

    private func setCircleMuted(_ muted: Bool, _ circleID: String) {
        Task {
            do {
                try await circles.setCircleMuted(muted, circleID: circleID)
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: muted ? "mute the circle" : "unmute the circle")
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

    private var leaveMessage: String {
        guard let detail else { return "" }
        if detail.circle.isCreator, detail.members.count > 1 {
            return "You started this circle. It passes to the member who has been in it longest."
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
            await circles.loadFeed(circleID: id)
        } catch {
            self.error = CircleStore.message(for: error, doing: "load the circle")
        }
    }

    private func leave() {
        Task {
            do {
                try await circles.leave(circleID: id)
                dismiss()
            } catch {
                self.error = CircleStore.message(for: error, doing: "leave the circle")
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
                    Text("Started the circle").font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
                }
            }
            if isMuted {
                Spacer()
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
                        ShareLink(item: invite.url, subject: Text("Join \(circleName) on Bird Journal"), message: Text("Join my circle \(circleName) on Bird Journal")) {
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
