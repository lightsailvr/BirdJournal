import Pack
import SwiftUI

/// Every photo of one species with its observer, exact license and links, the text source, and the way to the full
/// credits screen (issue #28).
struct SpeciesCreditsView: View {
    @Environment(PackLibrary.self) private var library
    let scientificName: String

    var body: some View {
        if let found = library.species(scientificName: scientificName) {
            List {
                Section {
                    ForEach(found.species.photos) { photo in
                        PhotoCreditRow(pack: found.pack, photo: photo)
                    }
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Each photo was cropped around the bird for the lens and the phone; nothing else was changed. Photographers keep their copyright unless the photo is CC0.")
                }
                if let source = found.species.descriptionSource {
                    Section("Text") {
                        Link("Adapted from English Wikipedia, CC BY-SA 4.0", destination: source)
                        Link("CC BY-SA 4.0 license", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
                    }
                }
                Section("Pack") {
                    LabeledContent("Bird pack", value: "\(found.pack.info.name), version \(found.pack.info.version)")
                    NavigationLink("All sources & credits", value: Route.credits)
                }
            }
            .paperList()
            .navigationTitle("Sources & credits")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("No pack describes this bird", systemImage: "bird")
        }
    }
}

/// One photo, small, with its observer, its license (linked to the deed) and its observation.
struct PhotoCreditRow: View {
    let pack: SpeciesPack
    let photo: PackPhoto

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PackImage(url: pack.lensImageURL(for: photo))
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(photo.observer)
                    .font(JournalFont.body)
                    .foregroundStyle(Color.ink)
                if let licenseURL = photo.licenseURL {
                    Link(photo.license, destination: licenseURL)
                        .font(JournalFont.attribution)
                } else {
                    Text(photo.license)
                        .font(JournalFont.attribution)
                        .foregroundStyle(Color.inkSecondary)
                }
                Link("Observation on iNaturalist", destination: photo.sourceURL)
                    .font(JournalFont.attribution)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
