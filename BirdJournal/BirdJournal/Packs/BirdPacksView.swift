import Album
import Pack
import SwiftUI

/// Bird packs (issue #28, over #13's library; the Atlas's storage page since #118): what is on the phone and what the
/// index offers, each row with its set cover (or the landscape its edition names), species and size from real
/// metadata, and every transfer state with its recovery: offline, interrupted, failed install and low storage.
struct BirdPacksView: View {
    @Environment(PackLibrary.self) private var library
    @State private var query = ""
    @State private var removalError: String?
    #if DEBUG
    @State private var statesPage: PackStatesPreview.Page?
    #endif

    private func matches(_ name: String, _ region: String?) -> Bool {
        NameSearch.matches(query: query, in: [name, region ?? ""])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Photos, sounds and field notes, ready offline. A download adds reference material, never birds; removing one keeps every patch, sighting, note and original photo.")
                    .font(JournalFont.body)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 2)

                SectionTitle("On your iPhone")
                VStack(spacing: 0) {
                    if let bundled = library.bundled, matches(bundled.info.name, bundled.info.region) {
                        let shown = library.bundledUpdate?.pack ?? bundled
                        NavigationLink(value: Route.pack(id: bundled.info.id)) {
                            PackRow(
                                name: shown.info.name, region: shown.info.region, setID: bundled.info.id, edition: shown.set?.edition.name,
                                facts: "\(shown.species.count) species, included with the app",
                                status: library.index?.descriptor(id: bundled.info.id).map(library.status(of:)) ?? .bundled,
                                descriptor: library.index?.descriptor(id: bundled.info.id)
                            )
                        }
                        .buttonStyle(.plain)
                        RowRule()
                    }
                    ForEach(library.downloads) { installed in
                        if matches(installed.pack.info.name, installed.pack.info.region) {
                            NavigationLink(value: Route.pack(id: installed.id)) {
                                PackRow(
                                    name: installed.pack.info.name, region: installed.pack.info.region, setID: installed.id, edition: installed.pack.set?.edition.name,
                                    facts: "\(installed.pack.species.count) species, \(installed.descriptor.byteCount.formatted(.byteCount(style: .file))) download",
                                    status: library.index?.descriptor(id: installed.id).map(library.status(of:)) ?? .installed(version: installed.descriptor.version),
                                    descriptor: library.index?.descriptor(id: installed.id) ?? installed.descriptor
                                )
                            }
                            .buttonStyle(.plain)
                            RowRule()
                        }
                    }
                }
                .padding(.top, 8)

                SectionTitle("More sets")
                if library.index == nil, library.isRefreshingIndex {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for sets…")
                    }
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 12)
                } else if library.indexError != nil, library.index == nil {
                    // Plain words, not the system's error string (issue #119: no diagnostics in a normal page).
                    ErrorNotice("Couldn't fetch the list of sets", message: "You may be offline. The downloads already on this iPhone, your collection and identification keep working.", symbol: "wifi.exclamationmark") {
                        Button("Try again") { Task { await library.refreshIndex() } }
                    }
                    .padding(.top, 12)
                } else if library.available.isEmpty, library.index != nil {
                    Text("Every set there is has been downloaded.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(library.available.filter { matches($0.name, $0.region) }) { descriptor in
                            NavigationLink(value: Route.pack(id: descriptor.id)) {
                                PackRow(
                                    name: descriptor.name, region: descriptor.region, setID: descriptor.id, edition: descriptor.set?.edition.name,
                                    facts: [descriptor.speciesCount.map { "\($0) species" }, "\(descriptor.byteCount.formatted(.byteCount(style: .file))) download"].compactMap { $0 }.joined(separator: ", "),
                                    status: library.status(of: descriptor), descriptor: descriptor
                                )
                            }
                            .buttonStyle(.plain)
                            RowRule()
                        }
                    }
                    .padding(.top, 8)
                }

                Text("A download adds photos and field notes for a set. Birds outside your downloads can still be identified by name.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, JournalLayout.sectionGap)
            }
            .padding(.horizontal, JournalLayout.margin)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .background(Color.paper)
        .navigationTitle("Field-guide downloads")
        .searchable(text: $query, prompt: "Find a set")
        .task { await library.refreshIndex() }
        .refreshable { await library.refreshIndex() }
        #if DEBUG
        .sheet(item: $statesPage) { page in NavigationStack { PackStatesPreview(page: page) } }
        .task {
            // Issue #118's screenshots: every transfer state, as the rows draw them (`-autoPackStates 1` to `4`).
            if let page = UserDefaults.standard.string(forKey: "autoPackStates") {
                UserDefaults.standard.removeObject(forKey: "autoPackStates")
                statesPage = PackStatesPreview.Page(id: min(PackStatesPreview.pages.count, max(1, Int(page) ?? 1)))
            }
        }
        #endif
    }
}

/// One pack: its set's cover (painted, from the index, or the landscape its edition names), name, edition and region,
/// facts, and the transfer control.
struct PackRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let name: String
    let region: String?
    let setID: String
    let edition: String?
    let facts: String
    let status: PackLibrary.Status
    let descriptor: PackDescriptor?

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows) {
            SetCoverImage(setID: setID, edition: edition ?? "")
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                if let line = [edition, region].compactMap({ $0?.isEmpty == false ? $0 : nil }).joined(separator: ", ").nilIfEmpty {
                    Text(line)
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                }
                Text(facts)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                PackTransferStatus(status: status, descriptor: descriptor, compact: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A pack's transfer state with its action: Download with the size, Update, progress in bytes and percent with Cancel,
/// Installing, Ready offline, or what went wrong (no connection, an interrupted download, a failed install, too little
/// space) with its recovery.
struct PackTransferStatus: View {
    @Environment(PackLibrary.self) private var library
    let status: PackLibrary.Status
    let descriptor: PackDescriptor?
    var compact = false

    var body: some View {
        switch status {
        case .bundled, .installed:
            ReadyOffline()
        case .notInstalled:
            if let descriptor {
                Button {
                    library.startDownload(descriptor)
                } label: {
                    Label(compact ? "Download" : "Download, \(descriptor.byteCount.formatted(.byteCount(style: .file)))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.journalOutlined)
                .padding(.top, 4)
                .accessibilityIdentifier("pack-download-\(descriptor.id)")
            }
        case .needsNewerApp:
            Label("Needs a newer version of Featherguild", systemImage: "arrow.up.circle")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
        case .updateAvailable(_, let available):
            if let descriptor {
                Button {
                    library.startDownload(descriptor)
                } label: {
                    Label(compact ? "Update to version \(available)" : "Update to version \(available), \(descriptor.byteCount.formatted(.byteCount(style: .file)))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.journalOutlined)
                .padding(.top, 4)
            }
        case .downloading(let received):
            if let descriptor {
                DownloadProgress(name: descriptor.name, received: received, total: Int64(descriptor.byteCount)) {
                    library.cancelDownload(id: descriptor.id)
                }
                .padding(.top, 4)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing: checking and unpacking…")
            }
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .padding(.top, 4)
        case .failed(let message):
            PackFailureView(failure: PackFailure(message: message)) {
                guard let descriptor else { return }
                library.dismissFailure(id: descriptor.id)
                library.startDownload(descriptor)
            }
            .padding(.top, 4)
        }
    }
}

/// A download under way: a bar, "41.2 MB of 173 MB, 24%", and Cancel.
struct DownloadProgress: View {
    let name: String
    let received: Int64
    let total: Int64
    let cancel: () -> Void

    var body: some View {
        let shown = min(received, total)
        let fraction = Double(shown) / Double(max(total, 1))
        let words = "\(shown.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file))), \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ProgressView(value: Double(shown), total: Double(max(total, 1)))
                    .tint(Color.moss)
                Button(action: cancel) {
                    Image(systemName: "xmark.circle")
                        .font(.title3)
                        .foregroundStyle(Color.inkSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Cancel download")
            }
            Text("Downloading, \(words)")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloading \(name), \(words)")
    }
}

/// What went wrong with a download, sorted from the library's message so each gets its own recovery (design guide
/// page 14). The library's words stay as the detail.
struct PackFailure: Equatable {
    enum Kind: Equatable {
        case offline, interrupted, lowStorage, install
    }

    let kind: Kind
    let message: String

    init(message: String) {
        self.message = message
        let words = message.lowercased()
        kind = if words.contains("space") { .lowStorage }
            else if words.contains("no internet") || words.contains("could not be reached") { .offline }
            else if words.contains("dropped") || words.contains("timed out") || words.contains("answered") { .interrupted }
            else { .install }
    }

    var title: String {
        switch kind {
        case .offline: "You're offline"
        case .interrupted: "The download was interrupted"
        case .lowStorage: "Not enough space"
        case .install: "The download couldn't be installed"
        }
    }

    var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .interrupted: "arrow.clockwise"
        case .lowStorage: "internaldrive"
        case .install: "exclamationmark.triangle"
        }
    }

    /// The recovery's button.
    var action: String {
        switch kind {
        case .offline, .interrupted: "Try again"
        case .lowStorage: "Check again"
        case .install: "Download again"
        }
    }

    /// A line after the library's words, where it helps.
    var advice: String? {
        switch kind {
        case .lowStorage: "Settings → General → iPhone Storage shows what takes the room. Nothing in your collection is touched."
        case .offline: "Downloads already on this iPhone keep working."
        case .interrupted: "Nothing was installed; the download starts over."
        case .install: "Nothing was installed, and nothing in your collection changed."
        }
    }
}

struct PackFailureView: View {
    let failure: PackFailure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.title, systemImage: failure.symbol)
                .font(JournalFont.supporting.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text([failure.message, failure.advice].compactMap { $0 }.joined(separator: " "))
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(failure.action, action: retry)
                .buttonStyle(.journalOutlined)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pack-failure")
    }
}

#if DEBUG
/// Every transfer state at once with a sample pack, for issue #118's screenshots (`-autoScreen packs -autoPackStates
/// YES`): the states pass too quickly to catch otherwise. The buttons do nothing here.
struct PackStatesPreview: View {
    @Environment(\.dismiss) private var dismiss
    /// A page of states, from 1: each fits one screen.
    struct Page: Identifiable { let id: Int }
    static let pages = [[0, 1, 2], [3, 4, 5], [6, 7], [8]]
    var page = Page(id: 1)

    private static let sample = PackDescriptor(
        id: "us-ca-sd", name: "San Diego", version: 1, url: URL(string: "https://example.invalid/sd.zip")!, sha256: "",
        byteCount: 173_000_000, speciesCount: 159, region: "San Diego County, California"
    )

    private static let states: [(String, PackLibrary.Status)] = [
        ("Not on this iPhone", .notInstalled),
        ("Downloading", .downloading(received: 41_200_000)),
        ("Installing", .installing),
        ("Ready offline", .installed(version: 1)),
        ("Update", .updateAvailable(installed: 1, available: 2)),
        ("Offline", .failed("No internet connection. Connect to Wi‑Fi or cellular data and try again.")),
        ("Interrupted", .failed("The connection dropped before the download finished. Try again.")),
        ("Failed install", .failed("The download's checksum did not match the index, so it was not installed. Try again.")),
        ("Low storage", .failed("Not enough space on this iPhone: the download needs about 450 MB free and 212 MB is available. Free some space and try again.")),
    ]

    var body: some View {
        PaperPage {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.pages[page.id - 1].map { Self.states[$0] }, id: \.0) { name, status in
                    Text(name)
                        .font(JournalFont.supporting.weight(.semibold))
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 18)
                    PackRow(
                        name: Self.sample.name, region: Self.sample.region, setID: Self.sample.id, edition: "Coastal edition",
                        facts: "159 species, 173 MB download", status: status, descriptor: Self.sample
                    )
                    RowRule()
                }
            }
        }
        .navigationTitle("Transfer states")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
#endif
