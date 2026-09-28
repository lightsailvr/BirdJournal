import Album
import Pack
import SwiftUI

/// Bird packs (issue #28, over #13's library): what is on the phone and what the index offers, each row with its
/// cover, species and size from real metadata, and every transfer state with its remedy.
struct BirdPacksView: View {
    @Environment(PackLibrary.self) private var library
    @State private var query = ""
    @State private var removalError: String?

    private func matches(_ name: String, _ region: String?) -> Bool {
        NameSearch.matches(query: query, in: [name, region ?? ""])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Photos and field notes, ready offline.")
                    .font(JournalFont.body)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 2)

                Text("On your iPhone")
                    .font(JournalFont.section)
                    .foregroundStyle(Color.ink)
                    .padding(.top, JournalLayout.sectionGap)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    if let bundled = library.bundled, matches(bundled.info.name, bundled.info.region) {
                        let shown = library.bundledUpdate?.pack ?? bundled
                        NavigationLink(value: Route.pack(id: bundled.info.id)) {
                            PackRow(
                                name: shown.info.name, region: shown.info.region, cover: cover(of: shown),
                                facts: "\(shown.species.count) species · Included",
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
                                    name: installed.pack.info.name, region: installed.pack.info.region, cover: cover(of: installed.pack),
                                    facts: "\(installed.pack.species.count) species · \(installed.descriptor.byteCount.formatted(.byteCount(style: .file)))",
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

                Text("Explore regions")
                    .font(JournalFont.section)
                    .foregroundStyle(Color.ink)
                    .padding(.top, JournalLayout.sectionGap)
                    .accessibilityAddTraits(.isHeader)
                if library.index == nil, library.isRefreshingIndex {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for packs…")
                    }
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 12)
                } else if let error = library.indexError, library.index == nil {
                    ErrorNotice("Could not fetch the list of packs", message: "\(error) The packs already on this iPhone keep working.", symbol: "wifi.exclamationmark") {
                        Button("Try again") { Task { await library.refreshIndex() } }
                    }
                    .padding(.top, 12)
                } else if library.available.isEmpty, library.index != nil {
                    Text("Every pack there is has been downloaded.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(library.available.filter { matches($0.name, $0.region) }) { descriptor in
                            NavigationLink(value: Route.pack(id: descriptor.id)) {
                                PackRow(
                                    name: descriptor.name, region: descriptor.region, cover: nil,
                                    facts: [descriptor.speciesCount.map { "\($0) species" }, descriptor.byteCount.formatted(.byteCount(style: .file))].compactMap { $0 }.joined(separator: " · "),
                                    status: library.status(of: descriptor), descriptor: descriptor
                                )
                            }
                            .buttonStyle(.plain)
                            RowRule()
                        }
                    }
                    .padding(.top, 8)
                }

                Text("Packs add photos and field notes for a region. Birds outside your packs can still be identified by name.")
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
        .navigationTitle("Bird packs")
        .searchable(text: $query, prompt: "Find a region")
        .task { await library.refreshIndex() }
        .refreshable { await library.refreshIndex() }
    }

    private func cover(of pack: SpeciesPack) -> URL? {
        pack.species.first?.photos.first.map(pack.lensImageURL(for:))
    }
}

/// One pack: its cover (the pack's first bird; no invented landscapes), name, region, facts, and the transfer control.
struct PackRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let name: String
    let region: String?
    let cover: URL?
    let facts: String
    let status: PackLibrary.Status
    let descriptor: PackDescriptor?

    var body: some View {
        AdaptiveRow(stacked: typeSize.stacksRows) {
            PackImage(url: cover)
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .overlay {
                    if cover == nil {
                        Image(systemName: "map")
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                if let region, !region.isEmpty {
                    Text(region)
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

/// A pack's transfer state with its action: Download with the size, Update, progress in bytes with Cancel,
/// Installing, Ready offline, Included, or why it failed and Try again.
struct PackTransferStatus: View {
    @Environment(PackLibrary.self) private var library
    let status: PackLibrary.Status
    let descriptor: PackDescriptor?
    var compact = false

    var body: some View {
        switch status {
        case .bundled:
            Label("Ready offline", systemImage: "checkmark.circle.fill")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.moss)
        case .installed:
            Label("Ready offline", systemImage: "checkmark.circle.fill")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.moss)
        case .notInstalled:
            if let descriptor {
                Button {
                    library.startDownload(descriptor)
                } label: {
                    Label(compact ? "Download" : "Download · \(descriptor.byteCount.formatted(.byteCount(style: .file)))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.journalOutlined)
                .padding(.top, 4)
            }
        case .updateAvailable(_, let available):
            if let descriptor {
                Button {
                    library.startDownload(descriptor)
                } label: {
                    Label(compact ? "Update to version \(available)" : "Update to version \(available) · \(descriptor.byteCount.formatted(.byteCount(style: .file)))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.journalOutlined)
                .padding(.top, 4)
            }
        case .downloading(let received):
            if let descriptor {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(min(received, Int64(descriptor.byteCount))), total: Double(max(descriptor.byteCount, 1)))
                            .tint(Color.moss)
                        Button {
                            library.cancelDownload(id: descriptor.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.title3)
                                .foregroundStyle(Color.inkSecondary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Cancel download")
                    }
                    Text("\(received.formatted(.byteCount(style: .file))) of \(descriptor.byteCount.formatted(.byteCount(style: .file)))")
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                        .monospacedDigit()
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Downloading \(descriptor.name), \(received.formatted(.byteCount(style: .file))) of \(descriptor.byteCount.formatted(.byteCount(style: .file)))")
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
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let descriptor {
                    Button("Try again") {
                        library.dismissFailure(id: descriptor.id)
                        library.startDownload(descriptor)
                    }
                    .buttonStyle(.journalOutlined)
                }
            }
            .padding(.top, 4)
        }
    }
}
