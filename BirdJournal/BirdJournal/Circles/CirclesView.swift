import SwiftUI

/// The Guilds tab (issue #61 as Circles, reskinned as Guilds in #118; issue #150, G3): an invitation to sign in while signed out, and
/// with no Guild yet a way to start one. With one Guild the tab is that Guild's page. With more it opens on what's new across them, on
/// felt: a row of emblems, each opening its Guild, over the merged feed. The models, routes and endpoints keep their Circle names.
struct CirclesView: View {
    @Environment(AccountSession.self) private var account
    @Environment(CircleStore.self) private var circles
    @Environment(PushCenter.self) private var pushes
    @State private var creating = false

    var body: some View {
        content
            .sheet(isPresented: $creating) { NewCircleSheet() }
            .task(id: account.status) {
                if account.isSignedIn {
                    // The account's ID marks the birder's own row on a Guild's page.
                    if account.account == nil { await account.loadAccount() }
                    await circles.refresh()
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
    }

    @ViewBuilder private var content: some View {
        if circles.isAvailable, account.isSignedIn, circles.circles.count == 1, let only = circles.circles.first {
            CirclePageView(id: only.id) { creating = true }
                .id(only.id)
        } else if circles.isAvailable, account.isSignedIn, circles.circles.count > 1 {
            AllGuildsPage(creating: $creating)
        } else {
            states
        }
    }

    /// Everything before there's a Guild to show: today's states, on a native list.
    private var states: some View {
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
        .refreshable { await circles.refresh() }
    }

    private var signedOut: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    GuildEmblem(identity: GuildIdentity(circleID: "featherguild"), size: 56)
                    WonderLine()
                    Text("A Guild is a small, invite-only group of up to 20 birders who see each other's finds and chase goals together. Sign in with Apple or Google to start one or join one from an invitation.")
                        .font(JournalFont.body)
                        .foregroundStyle(Color.inkSecondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            Section {
                SamplePatches()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            Section {
                SignInButtons()
            } footer: {
                Text("Your collection stays on this iPhone either way. An account is needed only for Guilds.")
            }
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
            empty
        }
    }

    private var empty: some View {
        Group {
            Section {
                WonderLine()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            Section {
                StateNotice(
                    "No Guilds yet",
                    message: "Start one for your family or your Sunday group, then invite friends with a link or a QR code. Got an invitation? Open its link on this iPhone.",
                    mark: .emblem(GuildIdentity(circleID: "featherguild"))
                ) {
                    VStack(spacing: 10) {
                        Button("Start a Guild") { creating = true }
                            .buttonStyle(.journalPrimary)
                        Label("Guilds are invite-only.", systemImage: "lock")
                            .font(JournalFont.attribution)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
        }
    }
}

/// "Find wonder together.", where a Guild is still to come (issue #150).
private struct WonderLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Find wonder together.", size: .lead, top: 0)
            Text("Small groups. Shared discoveries.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
        }
    }
}

/// What's new across the birder's Guilds (issue #150, G3): a row of emblems over the merged feed, on felt, with the last-known finds
/// at once and fresh ones a moment later.
private struct AllGuildsPage: View {
    @Environment(CircleStore.self) private var circles
    @Binding var creating: Bool
    @State private var reporting: ReportDraft?
    @State private var blocking: BlockedAccount?
    @State private var error: String?

    var body: some View {
        let feed = circles.mergedFeed
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GuildEmblemRow()
                    .padding(.top, 4)
                SectionTitle("What's new", size: .lead, top: 16, onBoard: true)
                finds(feed)
                if feed.hasMore {
                    MoreFinds(isLoading: feed.isLoading) { await circles.loadMoreMergedFeed() }
                }
                if let message = error ?? feed.error, !feed.entries.isEmpty {
                    InlineError(message).boardLabel().padding(.top, 12)
                }
                JoinWithAnInvite()
                    .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, JournalLayout.margin)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .patchSheetBackground()
        .holdsPatchLight()
        .navigationTitle("Guilds")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Guild", systemImage: "plus") { creating = true }
            }
        }
        .refreshable {
            await circles.refresh()
            await circles.loadMergedFeed()
        }
        // Each Guild's members and this month's goal, for its emblem's sentence: read once per Guild, then kept by the store.
        .task(id: circles.circles.map(\.id)) {
            for circle in circles.circles {
                if circles.needsDetail(circle.id) { try? await circles.loadDetail(id: circle.id) }
                if circles.needsGoals(circle.id) { await circles.loadGoals(circleID: circle.id) }
            }
        }
        // Runs again on the way back from a Guild or a find, which leaves what the birder was reading where it was.
        .task(id: circles.circles.map(\.id)) {
            await circles.loadMergedFeed(circleIDs: circles.circles.map(\.id).filter { circles.isFeedStale($0) })
        }
        .findSafety(reporting: $reporting, blocking: $blocking, subject: subject(of:), blocked: { error = $0 })
    }

    @ViewBuilder private func finds(_ feed: CircleStore.MergedFeed) -> some View {
        if feed.entries.isEmpty {
            if feed.isLoaded {
                StateNotice("No finds yet", message: "Birds your Guilds add while sharing show here.", messageInk: .ink)
                    .boardLabel()
                    .accessibilityIdentifier("feedEmpty")
            } else if let message = feed.error {
                GuildsUnreachable(message: message) { Task { await circles.loadMergedFeed() } }
                    .padding(.top, 12)
            } else {
                VStack(alignment: .leading, spacing: 12) { GuildPlaceholder() }
                    .padding(.top, 12)
            }
        }
        FindsColumn(
            entries: feed.entries, surface: .allGuilds, namesGuilds: true,
            onReport: { entry in
                if let circle = entry.circleIDs.first { reporting = .find(entry.item, circleID: circle) }
            },
            onBlock: { blocking = BlockedAccount(id: $0.id, displayName: $0.displayName) }
        )
    }

    private func subject(of draft: ReportDraft) -> String {
        let name = circles.mergedFeed.entries.first { $0.item.owner.id == draft.accountID }?.item.owner.name ?? "this member"
        return draft.kind == .find ? "\(name)'s find" : name
    }
}

/// The row of emblems above the merged feed, each opening its Guild. VoiceOver reads each Guild's name first, then who's in it and
/// how its month is going.
private struct GuildEmblemRow: View {
    @Environment(CircleStore.self) private var circles

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(circles.circles) { circle in
                    NavigationLink(value: Route.circle(id: circle.id)) {
                        GuildEmblemTile(circle: circle)
                    }
                    .buttonStyle(.patchLift)
                    .accessibilityLabel(Self.spoken(circle, goal: circles.goals[circle.id]?.first { $0.kind == .monthly }))
                    .accessibilityHint("Opens this Guild.")
                    .accessibilityIdentifier("guild-\(circle.id)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    /// "Sunday Group, 4 members, you started it, 9 of 14 species this month".
    static func spoken(_ circle: CircleSummary, goal: CircleGoal?) -> String {
        var parts = [circle.name, circle.memberCount == 1 ? "1 member" : "\(circle.memberCount) members"]
        if circle.isCreator { parts.append("you started it") }
        if let goal { parts.append("\(GoalWords.count(goal)) this month") }
        return parts.joined(separator: ", ")
    }
}

private struct GuildEmblemTile: View {
    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 84
    let circle: CircleSummary

    var body: some View {
        VStack(spacing: 6) {
            GuildEmblem(identity: GuildIdentity(circleID: circle.id), size: 68)
            Text(circle.name)
                .font(JournalFont.attribution.weight(.medium))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .boardLabel()
        }
        .frame(width: width)
        .contentShape(.rect)
    }
}

/// There is no scanner in the app: an invitation is a link, and the Camera opens its QR code as one.
private struct JoinWithAnInvite: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Join with an invite").font(JournalFont.rowTitle)
            Text("Open a friend's invitation link on this iPhone, or point the Camera at its QR code.")
                .font(JournalFont.supporting)
            Label("Guilds are invite-only.", systemImage: "lock")
                .font(JournalFont.attribution)
                .padding(.top, 6)
        }
        .foregroundStyle(Color.ink)
        .fixedSize(horizontal: false, vertical: true)
        .boardLabel()
        .accessibilityElement(children: .combine)
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
                    Section { InlineError(error, afterAction: true) }
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
