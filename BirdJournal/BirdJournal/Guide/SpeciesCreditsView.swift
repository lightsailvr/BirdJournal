import Pack
import SwiftUI

/// Every photo of one species with its observer, exact license and links, its reference sounds (issue #41), the text
/// source, and the way to the full credits screen (issue #28).
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
                if !found.species.sounds.isEmpty {
                    Section {
                        ForEach(found.species.sounds) { sound in
                            SoundCreditRow(sound: sound)
                        }
                    } header: {
                        Text("Sounds")
                    } footer: {
                        Text("Each sound is an 8-second excerpt of the recording, filtered and evened in loudness. Recordists keep their copyright unless the recording is CC0.")
                    }
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

/// One reference sound: its kind and length, the recordist, its license (linked to the deed) and the recording's page.
struct SoundCreditRow: View {
    let sound: PackSound

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sound.recordist)
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
            Text("\(sound.kind.rawValue.capitalized) · \(sound.duration.formatted(.units(allowed: [.seconds])))")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
            if let licenseURL = sound.licenseURL {
                Link(sound.license, destination: licenseURL)
                    .font(JournalFont.attribution)
            } else {
                Text(sound.license)
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.inkSecondary)
            }
            Link(sound.id.hasPrefix("xc-") ? "Recording on xeno-canto" : "Observation on iNaturalist", destination: sound.sourceURL)
                .font(JournalFont.attribution)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
