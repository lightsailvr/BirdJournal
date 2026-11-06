import SwiftUI

/// The Guilds tab (issue #61 as Circles, reskinned as Guilds in #118): an invitation to sign in while signed out, then
/// the birder's Guilds, each a card with its habitat cover and emblem, the members, and this month's shared goal, and a
/// way to start one. A Guild opens its page. The models, routes and endpoints keep their Circle names.
struct CirclesView: View {
    @Environment(AccountSession.self) private var account
    @Environment(CircleStore.self) private var circles
    @Environment(PushCenter.self) private var pushes
    @State private var creating = false

    var body: some View {
        PaperList {
            if !circles.isAvailable {
                Section {
                    Text("Guilds aren't available in this build yet.")
                        .foregroundStyle(Color.inkSecondary)
                }
            } else if !account.isSignedIn {
                signedOut
            } else {
                list
            }
            if let error = account.errorMessage, !account.isSignedIn {
                Section { InlineError(error) }
            }
        }
        .navigationTitle("Guilds")
        .toolbar {
            if circles.isAvailable, account.isSignedIn {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Guild", systemImage: "plus") { creating = true }
                }
            }
        }
        .sheet(isPresented: $creating) { NewCircleSheet() }
        .task(id: account.status) {
            if account.isSignedIn {
                // The account's ID marks the birder's own row on a Guild's page.
                if account.account == nil { await account.loadAccount() }
                await circles.refresh()
            }
        }
        // Each card's members and this month's goal: read once per Guild, then kept by the store.
        .task(id: circles.circles.map(\.id)) {
            for circle in circles.circles {
                if circles.needsDetail(circle.id) { try? await circles.loadDetail(id: circle.id) }
                if circles.needsGoals(circle.id) { await circles.loadGoals(circleID: circle.id) }
            }
        }
        // A notifications explanation that never got on screen gets one more chance (issue #107).
        .task { await pushes.circlesAppeared() }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "autoNewCircle") {
                UserDefaults.standard.removeObject(forKey: "autoNewCircle")
                creating = true
            }
        }
        #endif
        .refreshable { await circles.refresh() }
    }

    private var signedOut: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    GuildEmblem(identity: GuildIdentity(circleID: "featherguild"), size: 56)
                    Text("Bird with your friends")
                        .font(JournalFont.section)
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("A Guild is a small, invite-only group of up to 20 birders who see each other's finds and chase goals together. Sign in with Apple or Google to start one or join one from an invitation.")
                        .font(JournalFont.body)
                        .foregroundStyle(Color.inkSecondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            Section {
                SignInButtons()
            } footer: {
                Text("Your collection stays on this iPhone either way. An account is needed only for Guilds.")
            }
        }
    }

    private var intro: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find wonder together.")
                    .font(JournalFont.section)
                    .foregroundStyle(Color.ink)
                Text("Small groups. Shared discoveries.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
    }

    @ViewBuilder
    private var list: some View {
        switch circles.listState {
        case .idle, .loading where circles.circles.isEmpty:
            Section { GuildPlaceholder(rows: 2) }
        case .failed(let message) where circles.circles.isEmpty:
            // Offline or the server out of reach (issue #119): say so plainly, with what still works and Try again.
            Section {
                GuildsUnreachable(message: message) { Task { await circles.refresh() } }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
        default:
            if circles.circles.isEmpty {
                empty
            } else {
                intro
                Section {
                    ForEach(circles.circles) { circle in
                        NavigationLink(value: Route.circle(id: circle.id)) {
                            GuildCard(circle: circle, members: circles.details[circle.id]?.members, goal: circles.goals[circle.id]?.first { $0.kind == .monthly })
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                }
                joinWithInvite
            }
        }
    }

    /// There is no scanner in the app: an invitation is a link, and the Camera opens its QR code as one.
    private var joinWithInvite: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Join with an invite").font(JournalFont.rowTitle).foregroundStyle(Color.ink)
                    Text("Open a friend's invitation link on this iPhone, or point the Camera at its QR code.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
            } icon: {
                Image(systemName: "qrcode").foregroundStyle(Color.moss)
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Label("Guilds are invite-only.", systemImage: "lock")
                .frame(maxWidth: .infinity)
        }
    }

    private var empty: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                GuildEmblem(identity: GuildIdentity(circleID: "featherguild"), size: 56)
                Text("No Guilds yet")
                    .font(JournalFont.section)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Start one for your family or your Sunday group, then invite friends with a link or a QR code. Got an invitation? Open its link on this iPhone.")
                    .foregroundStyle(Color.inkSecondary)
                Button("Start a Guild") { creating = true }
                    .buttonStyle(.journalPrimary)
                    .padding(.top, 6)
                Label("Guilds are invite-only.", systemImage: "lock")
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }
}

/// One Guild in the list: its habitat cover, its emblem and name, who is in it, and this month's shared goal in the
/// lavender of shared goals once read. VoiceOver reads the name first.
private struct GuildCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let circle: CircleSummary
    let members: [CircleMember]?
    let goal: CircleGoal?

    var body: some View {
        let identity = GuildIdentity(circleID: circle.id)
        VStack(alignment: .leading, spacing: 0) {
            GuildCover(identity: identity)
                .frame(height: 104)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    GuildEmblem(identity: identity, size: 58)
                        .padding(.top, -34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(circle.name)
                            .font(JournalFont.heading)
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.leading)
                        Text(Self.subtitle(circle))
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                AdaptiveRow(stacked: typeSize.stacksRows) {
                    if let members, !members.isEmpty {
                        MemberFaces(members: members, total: circle.memberCount)
                    }
                    if !typeSize.stacksRows { Spacer(minLength: 8) }
                    HStack(spacing: 4) {
                        Text("View Guild")
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                    .font(JournalFont.supporting.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .accessibilityHidden(true)
                }
                if let goal {
                    GoalStrip(goal: goal)
                }
            }
            .padding(14)
        }
        .background(Color.raised)
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    static func subtitle(_ circle: CircleSummary) -> String {
        let members = circle.memberCount == 1 ? "1 member" : "\(circle.memberCount) members"
        return circle.isCreator ? "\(members) · You started it" : members
    }
}

/// This month's goal on a Guild's card: "23 of 30 species this month", a calm lavender bar and the share.
private struct GoalStrip: View {
    let goal: CircleGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(GoalWords.count(goal)) this month")
                    .font(JournalFont.supporting.weight(.medium))
                Spacer(minLength: 8)
                Text(GoalWords.fraction(goal).formatted(.percent.precision(.fractionLength(0))))
                    .font(JournalFont.attribution.monospacedDigit())
                    .accessibilityHidden(true)
            }
            GoalBar(goal: goal, height: 6, onLavender: true)
        }
        .foregroundStyle(Color.onSharedGoal)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.sharedGoal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Names a new Guild; the birder is its creator and first member.
struct NewCircleSheet: View {
    @Environment(CircleStore.self) private var circles
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            PaperList {
                Section {
                    TextField("Guild name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    Text("Up to 40 characters. Everyone in the Guild sees it.")
                }
                if let error {
                    Section { InlineError(error) }
                }
            }
            .navigationTitle("New Guild")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Create", action: create).disabled(trimmed.isEmpty || trimmed.count > 40)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard !trimmed.isEmpty, trimmed.count <= 40, !saving else { return }
        saving = true
        Task {
            do {
                try await circles.create(named: trimmed)
                dismiss()
            } catch {
                self.error = CircleStore.message(for: error, doing: "create the Guild")
            }
            saving = false
        }
    }
}

/// The Guilds can't be read (issue #119): offline, or the server out of reach. What happened in plain words, that the
/// collection, listening and the Atlas carry on without a connection, and Try again.
struct GuildsUnreachable: View {
    let message: String
    let retry: () -> Void

    private var isConnection: Bool { message.localizedCaseInsensitiveContains("connection") }

    var body: some View {
        ErrorNotice(
            isConnection ? "Can't reach your Guilds" : "Couldn't load your Guilds",
            message: isConnection ? "You may be offline. Your collection, listening and the Atlas all keep working; your Guilds come back when you're connected." : message,
            symbol: isConnection ? "wifi.slash" : "exclamationmark.triangle"
        ) {
            Button("Try again", action: retry)
        }
        .accessibilityIdentifier("guilds-unreachable")
    }
}
