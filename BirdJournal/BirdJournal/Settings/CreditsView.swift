import Identification
import Pack
import SwiftUI

/// Sources & credits (issues #11 and #28, spec user story 36): "Powered by BirdNET" with both models' licenses, then,
/// for every pack on the phone (#13), the text credit, each photo with its observer, exact license and observation
/// link, each reference sound with its recordist, license and recording page (#41), and the pack's LICENSE text. The
/// datasets behind the card stats (#55) follow the models when a pack carries stats, and the sources of the lore and
/// captions (#56) when a pack carries fact sheets.
struct CreditsView: View {
    @Environment(PackLibrary.self) private var library

    var body: some View {
        PaperList {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(ModelCredits.poweredBy, systemImage: "waveform")
                        .font(.headline)
                    Text("Birds are identified on this iPhone by the BirdNET models below. No audio leaves the phone.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
            }

            Section("Models") {
                ForEach(ModelCredits.models) { model in
                    ModelCreditRow(model: model)
                }
            }

            if library.packs.contains(where: { $0.species.contains { $0.stats != nil } }) {
                Section {
                    Text("Wingspan, weight, diet, habitat, migration, nest, clutch, lifestyle and the type line's family come from these datasets.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                    ForEach(StatsDataset.all) { dataset in
                        StatsDatasetRow(dataset: dataset)
                    }
                } header: {
                    Text("Bird stats")
                }
            }

            if library.packs.contains(where: { $0.species.contains { !$0.facts.isEmpty } }) {
                Section {
                    LoreCredits(packs: library.packs)
                } header: {
                    Text("Lore and captions")
                }
            }

            if library.packs.isEmpty {
                Section("Photos") {
                    Text("No field guide is on this iPhone, so there are no photos to credit.")
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            ForEach(library.packs, id: \.info.id) { pack in
                PhotoCreditSections(pack: pack)
            }
        }
        .navigationTitle("Sources & credits")
    }
}

/// Who writes the lore and the captions, from what (issue #56): each bird's fact sheet is its stats and sentences of its
/// Wikipedia article at the pack's revision; the lore is Claude's, reviewed by hand, CC BY-SA 4.0 with the article's
/// credit; captions are written on this iPhone by Apple's on-device model.
private struct LoreCredits: View {
    static let license = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    let packs: [SpeciesPack]

    var body: some View {
        let withLore = packs.reduce(0) { $0 + $1.species.count { $0.lore != nil } }
        VStack(alignment: .leading, spacing: 6) {
            Text("Each bird's fact sheet is its stats and sentences from its English Wikipedia article, at the article revision its set was built from (Wikipedia contributors, CC BY-SA 4.0). Each bird's Sources & credits links that revision.")
            if withLore > 0 {
                Text("The lore of \(withLore) birds was written by Claude (Anthropic) from the fact sheet alone, every sentence citing the facts it rests on, and reviewed by hand. As an adaptation of the Wikipedia text it is shared under CC BY-SA 4.0.")
            }
            Text("A sighting's caption is written on this iPhone by Apple's on-device model from the fact sheet and the moment: the season, the time of day, Heard or Seen, and the place, never for a threatened bird. Without the model the sighting shows the lore's tagline.")
        }
        .font(JournalFont.supporting)
        .foregroundStyle(Color.inkSecondary)
        .accessibilityIdentifier("credits-lore")
        Link("Wikipedia text and lore: CC BY-SA 4.0", destination: Self.license)
            .font(JournalFont.attribution)
    }
}

/// One model: name, role, license, its source and the license texts shipped with it.
private struct ModelCreditRow: View {
    let model: ModelAttribution

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.name).font(.headline)
            Text(model.role).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
            Link("License: \(model.license)", destination: model.licenseURL).font(JournalFont.attribution)
            Link("Source", destination: model.sourceURL).font(JournalFont.attribution)
            ForEach(model.licenseFileNames, id: \.self) { file in
                NavigationLink(file, value: Route.modelLicense(fileName: file))
                    .font(JournalFont.attribution)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One stats dataset: its name, the citation, its DOI and its license.
private struct StatsDatasetRow: View {
    let dataset: StatsDataset

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dataset.name).font(.headline)
            Text(dataset.citation).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
            Link("License: \(StatsDataset.license)", destination: StatsDataset.licenseURL).font(JournalFont.attribution)
            Link("Source", destination: dataset.url).font(JournalFont.attribution)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("credits-stats-\(dataset.source.rawValue)")
    }
}

/// Every photo in the pack, one row each, grouped by species, the text credit, then the pack's own LICENSE.
private struct PhotoCreditSections: View {
    static let wikipediaLicense = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    let pack: SpeciesPack

    var body: some View {
        Section {
            Text("\(pack.photos.count) photos from iNaturalist observations, each under the Creative Commons license its photographer chose and cropped around the bird for this app. Photographers keep their copyright unless the photo is CC0.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
            let described = pack.species.filter { $0.descriptionSource != nil }.count
            if described > 0 {
                Text("Descriptions of \(described) species are adapted from English Wikipedia articles by Wikipedia contributors. Each bird's Sources & credits links the article revision it came from.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                Link("Wikipedia text: CC BY-SA 4.0", destination: Self.wikipediaLicense)
                    .font(JournalFont.attribution)
            }
            if !pack.sounds.isEmpty {
                Text("\(pack.sounds.count) sounds are 8-second excerpts of recordings from xeno-canto and iNaturalist, filtered and evened in loudness for this app, each under the Creative Commons license its recordist chose. Recordists keep their copyright unless the recording is CC0.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
            NavigationLink("Pack license (\(pack.info.id) v\(pack.info.version))", value: Route.packLicense(id: pack.info.id))
        } header: {
            Text(pack.sounds.isEmpty ? "Photos and text: \(pack.info.name)" : "Photos, sounds and text: \(pack.info.name)")
        }
        ForEach(pack.species) { species in
            Section(species.commonName) {
                ForEach(species.photos) { photo in
                    PhotoCreditRow(pack: pack, photo: photo)
                }
                ForEach(species.sounds) { sound in
                    SoundCreditRow(sound: sound)
                }
            }
        }
    }
}

/// A license text as shipped, verbatim, read once when the screen appears.
struct LicenseTextView: View {
    let title: String
    let load: () throws -> String
    @State private var text: Result<String, any Error>?

    var body: some View {
        ScrollView {
            switch text {
            case .success(let text):
                Text(text)
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            case .failure:
                StateNotice("License text missing", message: "This build doesn't carry the full license text. The credits page still names the work, its author and its license.", mark: .symbol("doc"))
                    .padding(.horizontal, JournalLayout.margin)
            case nil:
                ProgressView()
            }
        }
        .background(Color.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { text = Result(catching: load) }
    }
}
