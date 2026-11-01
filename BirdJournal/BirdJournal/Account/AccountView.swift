import SwiftUI

/// Settings → Account (issue #60): Sign in with Apple or Google while signed out; the name circles will show, the
/// email and Sign out while signed in. The account is optional, and the screen says so.
struct AccountView: View {
    @Environment(AccountSession.self) private var account
    @State private var name = ""
    @State private var confirmingSignOut = false

    var body: some View {
        List {
            switch account.status {
            case .unavailable:
                Section {
                    Text("Accounts aren't available in this build yet.")
                        .foregroundStyle(Color.inkSecondary)
                } footer: {
                    Text(Self.optionalNote)
                }
            case .signedOut, .signingIn:
                signedOut
            case .signedIn:
                signedIn
            }
            if let error = account.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).font(JournalFont.supporting)
                }
            }
        }
        .paperList()
        .navigationTitle("Account")
        .task(id: account.status) {
            if account.isSignedIn, account.account == nil { await account.loadAccount() }
        }
        .onChange(of: account.account?.displayName, initial: true) { _, displayName in
            name = displayName ?? ""
        }
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { account.signOut() }
        } message: {
            Text("Your journal and cards stay on this iPhone.")
        }
    }

    private var signedOut: some View {
        Section {
            SignInButtons()
        } header: {
            Text("Sign in")
        } footer: {
            Text(Self.optionalNote)
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        Section {
            TextField("Your name", text: $name)
                .textContentType(.name)
                .submitLabel(.done)
                .onSubmit { Task { await account.setDisplayName(name) } }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != account.account?.displayName {
                Button("Save name") { Task { await account.setDisplayName(name) } }
            }
            if let email = account.identity.email {
                LabeledContent("Email", value: email)
            }
        } header: {
            Text("Signed in")
        } footer: {
            Text("Your name is what friends will see in your circles.")
        }
        Section {
            Button("Sign out", role: .destructive) { confirmingSignOut = true }
        } footer: {
            Text("Signing out keeps your journal and cards on this iPhone.")
        }
    }

    static let optionalNote = "An account is optional. Listening, your journal, cards and bird packs all work without one; signing in will let you join circles with friends."
}

/// Sign in with Apple and with Google, as list rows: Settings → Account, the Circles tab and the join screen.
struct SignInButtons: View {
    @Environment(AccountSession.self) private var account

    var body: some View {
        ForEach(IdentityProvider.allCases) { provider in
            Button {
                Task { await account.signIn(with: provider) }
            } label: {
                HStack(spacing: 8) {
                    if account.status == .signingIn(provider) {
                        ProgressView()
                    } else if provider == .apple {
                        Image(systemName: "apple.logo")
                    }
                    Text(provider.buttonTitle)
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(provider == .apple ? Color.white : Color.ink)
                .background(provider == .apple ? Color.black : Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous).strokeBorder(Color.rule, lineWidth: provider == .apple ? 0 : 1))
            }
            .buttonStyle(.plain)
            .disabled(account.status != .signedOut)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}

/// The Account row on the Settings screen: who is signed in, or that nobody is.
struct AccountRow: View {
    @Environment(AccountSession.self) private var account

    var body: some View {
        NavigationLink(value: Route.account) {
            LabeledContent("Account", value: summary)
        }
    }

    private var summary: String {
        switch account.status {
        case .unavailable, .signedOut, .signingIn: "Not signed in"
        case .signedIn: account.account?.displayName ?? account.identity.name ?? account.identity.email ?? "Signed in"
        }
    }
}
