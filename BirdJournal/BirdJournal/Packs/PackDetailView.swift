import Pack
import SwiftUI

/// One pack in detail (issue #28): a preview of its birds, what it holds, the storage it needs or takes, its version
/// and credits, and its download, update or removal. Works for a pack on the phone and for one the index offers.
struct PackDetailView: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var confirmingRemoval = false
    @State private var removalError: String?

    private var installed: SpeciesPack? { library.pack(id: id) }
    private var descriptor: PackDescriptor? { library.index?.descriptor(id: id) ?? library.installed.first { $0.id == id }?.descriptor }
    private var isBundled: Bool { library.bundled?.info.id == id }
    private var isDownload: Bool { library.downloads.contains { $0.id == id } }
    private var isBundledUpdate: Bool { library.bundledUpdate?.id == id }

    var body: some View {
        let name = installed?.info.name ?? descriptor?.name ?? id
        PaperPage {
            VStack(alignment: .leading, spacing: 0) {
                if let region = installed?.info.region ?? descriptor?.region {
                    Text(region)
                        .font(JournalFont.body)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 2)
                }
                if let installed {
                    PackPreview(pack: installed)
                        .padding(.top, 16)
                }

                let status = descriptor.map(library.status(of:)) ?? (installed == nil ? .notInstalled : .bundled)
                PackTransferStatus(status: status, descriptor: descriptor)
                    .padding(.top, 20)
                if isBundled, !isBundledUpdate {
                    Text("Included with the app: this pack is always here, and cannot be removed.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 8)
                }

                SectionTitle(text: "What it holds")
                VStack(spacing: 0) {
                    let species = installed?.species.count ?? descriptor?.speciesCount
                    let photos = installed?.photos.count ?? descriptor?.photoCount
                    FactRow(label: "Birds", value: species.map { "\($0) species with photos and field notes" } ?? "Listed once downloaded")
                    RowRule()
                    FactRow(label: "Photos", value: photos.map { "\($0), each credited to its photographer" } ?? "Listed once downloaded")
                    RowRule()
                    if let descriptor {
                        FactRow(label: "Download", value: descriptor.byteCount.formatted(.byteCount(style: .file)))
                        RowRule()
                    }
                    if let installed {
                        FactRow(label: "On this iPhone", value: PackStorage.diskUsage(of: installed.directory).formatted(.byteCount(style: .file)))
                        RowRule()
                    } else if let descriptor {
                        FactRow(label: "Storage needed", value: "About \((Int64(descriptor.byteCount) * 2).formatted(.byteCount(style: .file))) free during the download")
                        RowRule()
                    }
                    FactRow(label: "Version", value: versionText)
                    RowRule()
                    FactRow(label: "Works offline", value: installed != nil ? "Yes" : "Once downloaded")
                }
                .padding(.top, 8)

                SectionTitle(text: "Sources & credits")
                Text("Photos come from iNaturalist observations under the Creative Commons licenses their photographers chose, cropped for this app. Text is adapted from English Wikipedia under CC BY-SA 4.0. Identification is powered by BirdNET.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 12)
                if installed != nil {
                    NavigationLink(value: Route.packLicense(id: id)) {
                        Label("Pack license and every credit", systemImage: "text.document")
                    }
                    .buttonStyle(.journalOutlined)
                    .padding(.top, 10)
                }

                if isDownload || isBundledUpdate {
                    SectionTitle(text: "Storage")
                    Text(isBundledUpdate ? "Removing this update goes back to the copy of the pack in the app." : "Removing the pack frees its space. Your journal keeps every sighting, note and snapshot; birds from this pack are then named without photos until it is downloaded again.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 12)
                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label(isBundledUpdate ? "Remove update" : "Remove pack", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .padding(.top, 12)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(isBundledUpdate ? "Remove the downloaded update?" : "Remove \(name) from this iPhone?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(isBundledUpdate ? "Remove update" : "Remove pack", role: .destructive) {
                do {
                    try library.remove(id: id)
                    dismiss()
                } catch {
                    removalError = error.localizedDescription
                }
            }
        } message: {
            Text("Your journal is not affected. The pack can be downloaded again.")
        }
        .alert("The pack could not be removed", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK") { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    private var versionText: String {
        switch (installed?.info.version, descriptor?.version) {
        case let (installed?, available?) where available > installed: "\(installed) on this iPhone, \(available) available"
        case let (installed?, _): "\(installed)"
        case let (nil, available?): "\(available)"
        default: "Unknown"
        }
    }
}

/// A strip of the pack's birds, then the full list.
private struct PackPreview: View {
    let pack: SpeciesPack
    @State private var showingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pack.species.prefix(12)) { species in
                        NavigationLink(value: Route.species(scientificName: species.scientificName, commonName: species.commonName)) {
                            VStack(alignment: .leading, spacing: 4) {
                                PackImage(url: species.photos.first.map(pack.lensImageURL(for:)))
                                    .frame(width: 120, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                                Text(species.commonName)
                                    .font(JournalFont.attribution)
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(species.commonName)
                    }
                }
            }
            .scrollClipDisabled()
            DisclosureGroup("All \(pack.species.count) birds", isExpanded: $showingAll) {
                VStack(spacing: 0) {
                    ForEach(pack.species) { species in
                        NavigationLink(value: Route.species(scientificName: species.scientificName, commonName: species.commonName)) {
                            HStack {
                                Text(species.commonName)
                                    .font(JournalFont.body)
                                    .foregroundStyle(Color.ink)
                                Spacer()
                                Text(species.scientificName)
                                    .font(JournalFont.scientific)
                                    .foregroundStyle(Color.inkSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        RowRule()
                    }
                }
                .padding(.top, 6)
            }
            .font(JournalFont.body)
            .foregroundStyle(Color.ink)
            .tint(Color.moss)
        }
    }
}
