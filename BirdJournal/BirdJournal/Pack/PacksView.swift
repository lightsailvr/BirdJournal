import Pack
import SwiftUI

/// Species packs on the phone (issue #13): the bundled pack and every download, each opening its species list, and
/// the packs the index offers, with a download that shows its progress and a delete that frees the space.
struct PacksView: View {
    @Environment(PackLibrary.self) private var library
    @State private var removalError: String?

    var body: some View {
        List {
            Section {
                if let bundled = library.bundled {
                    PackRow(pack: bundled, detail: "Included with the app", descriptor: library.index?.descriptor(id: bundled.info.id))
                }
                ForEach(library.installed) { installed in
                    PackRow(pack: installed.pack, detail: Self.sizeText(installed.descriptor.byteCount), descriptor: library.index?.descriptor(id: installed.id) ?? installed.descriptor)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                do { try library.remove(id: installed.id) } catch { removalError = error.localizedDescription }
                            }
                        }
                }
            } header: {
                Text("On this phone")
            } footer: {
                Text("Every pack's species are shown on the lens and named in the album. Swipe a downloaded pack to delete it.")
            }

            Section {
                if library.available.isEmpty, library.index != nil {
                    Text("Every pack in the index is on this phone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.available) { descriptor in
                    AvailablePackRow(descriptor: descriptor)
                }
            } header: {
                HStack {
                    Text("Available to download")
                    if library.isRefreshingIndex { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if let error = library.indexError {
                    Text("The pack index could not be fetched: \(error)")
                } else if library.index == nil {
                    Text("Fetching the pack index…")
                } else {
                    Text("Packs are downloaded from \(library.indexURL.host() ?? library.indexURL.absoluteString) and checked against the index before use.")
                }
            }
        }
        .navigationTitle("Species packs")
        .task { await library.refreshIndex() }
        .refreshable { await library.refreshIndex() }
        .alert("The pack could not be deleted", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK") { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A pack on the phone: its name and species count, a link to its list, and an update when the index has a newer version.
private struct PackRow: View {
    @Environment(PackLibrary.self) private var library
    let pack: SpeciesPack
    let detail: String
    let descriptor: PackDescriptor?

    var body: some View {
        NavigationLink(value: ContentView.Screen.pack(id: pack.info.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.info.name)
                Text("\(pack.species.count) species · \(detail)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let descriptor {
                    TransferStatus(descriptor: descriptor)
                }
            }
        }
    }
}

/// A pack from the index that is not on the phone: name, size, and its download.
private struct AvailablePackRow: View {
    @Environment(PackLibrary.self) private var library
    let descriptor: PackDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.name)
            Text("Version \(descriptor.version) · \(PacksView.sizeText(descriptor.byteCount))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TransferStatus(descriptor: descriptor)
        }
    }
}

/// The download control for one pack: a Download or Update button, a progress bar with Cancel while it runs, or
/// why the last attempt failed with a Retry.
private struct TransferStatus: View {
    @Environment(PackLibrary.self) private var library
    let descriptor: PackDescriptor

    var body: some View {
        switch library.status(of: descriptor) {
        case .bundled, .installed:
            EmptyView()
        case .notInstalled:
            Button("Download") { library.startDownload(descriptor) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
        case .updateAvailable(_, let available):
            Button("Update to version \(available)") { library.startDownload(descriptor) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
        case .downloading(let received):
            HStack {
                ProgressView(value: Double(min(received, Int64(descriptor.byteCount))), total: Double(max(descriptor.byteCount, 1)))
                Button("Cancel") { library.cancelDownload(id: descriptor.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            .padding(.top, 4)
            .accessibilityLabel("Downloading \(descriptor.name), \(PacksView.sizeText(Int(received))) of \(PacksView.sizeText(descriptor.byteCount))")
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking and unpacking…").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Retry") {
                    library.dismissFailure(id: descriptor.id)
                    library.startDownload(descriptor)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }
}
