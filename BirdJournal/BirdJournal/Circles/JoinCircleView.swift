import SwiftUI

/// The join screen (issue #61), opened by an invite link: sign in if needed, see the Guild's name, emblem, size and
/// who invited, then join. A link to a Guild the birder is already in just opens it. Pushed on the Guilds tab, so the
/// back button is the way out.
struct JoinCircleView: View {
    @Environment(AccountSession.self) private var account
    @Environment(CircleStore.self) private var circles
    @Environment(\.openCircle) private var openCircle
    let token: String
    @State private var preview: InvitePreview?
    @State private var error: String?
    @State private var joining = false

    var body: some View {
        PaperList {
            if !circles.isAvailable {
                Section { Text("Guilds aren't available in this build yet.").foregroundStyle(Color.inkSecondary) }
            } else if !account.isSignedIn {
                Section {
                    intro(title: "You're invited to a Guild", text: "Sign in with Apple or Google to see the invitation and join. Your collection stays on this iPhone either way.")
                }
                Section { SignInButtons() }
            } else if let preview {
                invitation(preview)
            } else if let error {
                Section { intro(title: "Can't open this invitation", text: error) }
            } else {
                Section { GuildPlaceholder(rows: 1) }
            }
            if let message = account.errorMessage, !account.isSignedIn {
                Section { InlineError(message) }
            }
        }
        .navigationTitle("Join a Guild")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: account.status) { await load() }
    }

    private func intro(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GuildEmblem(identity: GuildIdentity(circleID: token), size: 56)
            SectionTitle(title, size: .lead, top: 0)
            Text(text).foregroundStyle(Color.inkSecondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func invitation(_ preview: InvitePreview) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                GuildEmblem(identity: GuildIdentity(circleID: preview.circle.id), size: 64)
                Text(preview.circle.name).font(JournalFont.title)
                Text(details(preview)).foregroundStyle(Color.inkSecondary)
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
        Section {
            if preview.alreadyMember {
                Button("Open the Guild") { finish(preview.circle.id) }
                    .buttonStyle(.journalPrimary)
            } else if preview.circle.memberCount >= 20 {
                Text("This Guild is full: a Guild holds 20 birders.").foregroundStyle(Color.inkSecondary)
            } else {
                Button {
                    join()
                } label: {
                    if joining { ProgressView() } else { Text("Join Guild") }
                }
                .buttonStyle(.journalPrimary)
                .disabled(joining)
            }
        } footer: {
            Text("Members see the birds each other finds, with the species, the city and the time. You can leave at any time.")
        }
        .listRowBackground(Color.clear)
        if let error {
            Section { InlineError(error) }
        }
    }

    private func details(_ preview: InvitePreview) -> String {
        let members = preview.circle.memberCount == 1 ? "1 member" : "\(preview.circle.memberCount) members"
        let from = preview.invitedBy.map { "Invited by \($0). " } ?? ""
        if preview.alreadyMember { return "\(from)\(members). You're already in this Guild." }
        return "\(from)\(members). The invitation expires \(preview.expiresAt.formatted(date: .abbreviated, time: .omitted))."
    }

    private func load() async {
        guard circles.isAvailable, account.isSignedIn, preview == nil else { return }
        do {
            preview = try await circles.preview(token: token)
            error = nil
        } catch {
            self.error = CircleStore.message(for: error, doing: "open the invitation")
        }
    }

    private func join() {
        joining = true
        Task {
            do {
                let detail = try await circles.accept(token: token)
                finish(detail.circle.id)
            } catch {
                self.error = CircleStore.message(for: error, doing: "join the Guild")
            }
            joining = false
        }
    }

    /// Replaces the join screen with the Guild's page.
    private func finish(_ circleID: String) {
        openCircle(circleID)
    }
}
