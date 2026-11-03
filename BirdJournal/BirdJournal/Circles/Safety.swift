import SwiftUI

/// Reports and blocks (issue #71): a member reports a friend's find or a member, and blocks an account, from the
/// circle's page; the blocked list, to unblock, is under Settings → Account.

enum ReportReason: String, CaseIterable, Identifiable, Encodable, Sendable {
    case inappropriate, harassment, spam, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inappropriate: "Inappropriate content"
        case .harassment: "Harassment or bullying"
        case .spam: "Spam"
        case .other: "Something else"
        }
    }
}

/// What a report names: a find (its owner and sighting) or an account, and the circle where the reporter saw it.
struct ReportDraft: Equatable, Sendable, Encodable {
    enum Kind: String, Encodable, Sendable { case find, account }

    var kind: Kind
    var accountID: String
    var circleID: String
    var sightingID: String?
    var reason: ReportReason = .inappropriate
    var details: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case accountID = "account_id"
        case circleID = "circle_id"
        case sightingID = "sighting_id"
        case reason, details
    }

    static func find(_ item: FeedItem, circleID: String) -> ReportDraft {
        ReportDraft(kind: .find, accountID: item.owner.id, circleID: circleID, sightingID: item.sightingID)
    }

    static func account(_ member: CircleMember, circleID: String) -> ReportDraft {
        ReportDraft(kind: .account, accountID: member.id, circleID: circleID)
    }

    /// The body the server takes: no empty details.
    var sent: ReportDraft {
        var draft = self
        draft.details = details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return draft
    }
}

extension ReportDraft: Identifiable {
    var id: String { "\(kind.rawValue)-\(accountID)-\(sightingID ?? "")" }
}

struct BlockedAccount: Equatable, Identifiable, Decodable, Sendable {
    var id: String
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    var name: String { displayName ?? "A birder" }
}

/// Report a find or a member: a reason and, if the birder wants, a few words. Sent to the maintainer; nobody else
/// sees it.
struct ReportSheet: View {
    @Environment(CircleStore.self) private var circles
    @Environment(\.dismiss) private var dismiss
    @State var draft: ReportDraft
    let subject: String
    @State private var details = ""
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        Label("Thanks. Your report was sent.", systemImage: "checkmark.circle")
                            .accessibilityIdentifier("reportSent")
                    } footer: {
                        Text("We read every report and act on what breaks the rules. \(subject.capitalizedFirst) isn't told who reported it.")
                    }
                } else {
                    Section {
                        Picker("Reason", selection: $draft.reason) {
                            ForEach(ReportReason.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .accessibilityIdentifier("reportReason")
                    } header: {
                        Text("What's wrong with \(subject)?")
                    }
                    Section {
                        TextField("Anything else we should know (optional)", text: $details, axis: .vertical)
                            .lineLimit(3...6)
                            .accessibilityIdentifier("reportDetails")
                    } footer: {
                        Text("Your report goes to Featherguild only, with what you saw. To stop seeing someone, block them too.")
                    }
                    if let error {
                        Section { InlineError(error) }
                    }
                }
            }
            .navigationTitle(draft.kind == .find ? "Report find" : "Report member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { send() }
                            .disabled(sending)
                            .accessibilityIdentifier("reportSend")
                    }
                }
            }
        }
    }

    private func send() {
        sending = true
        var report = draft
        report.details = details
        Task {
            defer { sending = false }
            do {
                try await circles.report(report.sent)
                sent = true
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: "send the report")
            }
        }
    }
}

/// Settings → Account → Blocked accounts: who the birder blocked, each with Unblock.
struct BlockedAccountsView: View {
    @Environment(CircleStore.self) private var circles
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if circles.blocked.isEmpty {
                    Text("You haven't blocked anyone.")
                        .foregroundStyle(Color.inkSecondary)
                        .accessibilityIdentifier("noBlocks")
                }
                ForEach(circles.blocked) { account in
                    HStack {
                        Text(account.name).font(JournalFont.rowTitle)
                        Spacer()
                        Button("Unblock") { unblock(account) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("unblock-\(account.id)")
                    }
                }
            } footer: {
                Text("You don't see a blocked member's finds or reactions, and you aren't notified about them. They aren't told.")
            }
            if let error {
                Section { InlineError(error) }
            }
        }
        .paperList()
        .navigationTitle("Blocked accounts")
        .task { await circles.loadBlocks() }
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
}
