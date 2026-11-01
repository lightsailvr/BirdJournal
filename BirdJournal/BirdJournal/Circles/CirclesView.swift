import SwiftUI

/// The Circle tab (issue #61): an invitation to sign in while signed out, then the birder's circles and a way to
/// start one. A circle opens its page. Finds, goals and the feed arrive with later tickets.
struct CirclesView: View {
    @Environment(AccountSession.self) private var account
    @Environment(CircleStore.self) private var circles
    @State private var creating = false

    var body: some View {
        List {
            if !circles.isAvailable {
                Section {
                    Text("Circles aren't available in this build yet.")
                        .foregroundStyle(Color.inkSecondary)
                }
            } else if !account.isSignedIn {
                signedOut
            } else {
                list
            }
            if let error = account.errorMessage, !account.isSignedIn {
                Section { Text(error).foregroundStyle(.red).font(JournalFont.supporting) }
            }
        }
        .paperList()
        .navigationTitle("Circles")
        .toolbar {
            if circles.isAvailable, account.isSignedIn {
                ToolbarItem(placement: .primaryAction) {
                    Button("New circle", systemImage: "plus") { creating = true }
                }
            }
        }
        .sheet(isPresented: $creating) { NewCircleSheet() }
        .task(id: account.status) {
            if account.isSignedIn {
                // The account's ID marks the birder's own row on a circle's page.
                if account.account == nil { await account.loadAccount() }
                await circles.refresh()
            } else {
                circles.clear()
            }
        }
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
                    Image(systemName: "person.3")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.moss)
                        .accessibilityHidden(true)
                    Text("Bird with your friends")
                        .font(JournalFont.section)
                    Text("A circle is a small group of up to 20 birders who see each other's finds and chase goals together. Sign in with Apple or Google to start one or join one from an invitation.")
                        .font(JournalFont.body)
                        .foregroundStyle(Color.inkSecondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            Section {
                SignInButtons()
            } footer: {
                Text("Your journal and cards stay on this iPhone either way. An account is needed only for circles.")
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        switch circles.listState {
        case .idle, .loading where circles.circles.isEmpty:
            Section { ProgressView().frame(maxWidth: .infinity) }
                .listRowBackground(Color.clear)
        case .failed(let message) where circles.circles.isEmpty:
            Section {
                Text(message).foregroundStyle(Color.inkSecondary)
                Button("Try again") { Task { await circles.refresh() } }
            }
        default:
            if circles.circles.isEmpty {
                empty
            } else {
                Section {
                    ForEach(circles.circles) { circle in
                        NavigationLink(value: Route.circle(id: circle.id)) {
                            CircleRow(circle: circle)
                        }
                    }
                } footer: {
                    Text("Open a circle to invite friends with a link or QR code.")
                }
            }
        }
    }

    private var empty: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("No circles yet")
                    .font(JournalFont.section)
                Text("Start one for your family or your Sunday group, then invite friends with a link or a QR code. Got an invitation? Open its link on this iPhone.")
                    .foregroundStyle(Color.inkSecondary)
                Button("Start a circle") { creating = true }
                    .buttonStyle(.journalPrimary)
                    .padding(.top, 6)
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }
}

private struct CircleRow: View {
    let circle: CircleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(circle.name).font(JournalFont.rowTitle)
            Text(subtitle).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let members = circle.memberCount == 1 ? "1 member" : "\(circle.memberCount) members"
        return circle.isCreator ? "\(members) · You started it" : members
    }
}

/// Names a new circle; the birder is its creator and first member.
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
            List {
                Section {
                    TextField("Circle name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    Text("Up to 40 characters. Everyone in the circle sees it.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(JournalFont.supporting) }
                }
            }
            .paperList()
            .navigationTitle("New circle")
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
                self.error = CircleStore.message(for: error, doing: "create the circle")
            }
            saving = false
        }
    }
}
