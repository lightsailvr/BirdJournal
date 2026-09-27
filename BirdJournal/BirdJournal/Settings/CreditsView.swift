import Identification
import Pack
import SwiftUI

/// Credits (issue #11, spec user story 36): "Powered by BirdNET" with both models' licenses, then every photo in the
/// bundled pack with its observer, license and observation link, the Wikipedia text credit (issue #12) and the pack's
/// LICENSE text.
struct CreditsView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(ModelCredits.poweredBy, systemImage: "waveform")
                        .font(.headline)
                    Text("Birds are identified on the phone by the BirdNET models below. No audio leaves the phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Models") {
                ForEach(ModelCredits.models) { model in
                    ModelCreditRow(model: model)
                }
            }

            switch BundledPack.loaded {
            case .success(let pack):
                PhotoCreditSections(pack: pack)
            case .failure:
                Section("Photos") {
                    Text("No species pack is loaded, so there are no photos to credit.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Credits")
    }
}

/// One model: name, role, license, its source and the license texts shipped with it.
private struct ModelCreditRow: View {
    let model: ModelAttribution

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.name).font(.headline)
            Text(model.role).font(.footnote).foregroundStyle(.secondary)
            Link("License: \(model.license)", destination: model.licenseURL).font(.footnote)
            Link("Source", destination: model.sourceURL).font(.footnote)
            ForEach(model.licenseFileNames, id: \.self) { file in
                NavigationLink(file, value: ContentView.Screen.modelLicense(fileName: file))
                    .font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Every photo in the pack, one row each, grouped by species, the text credit, then the pack's own LICENSE.
private struct PhotoCreditSections: View {
    static let wikipediaLicense = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    let pack: SpeciesPack

    var body: some View {
        Section {
            Text("\(pack.photos.count) photos from iNaturalist Open Data, each under the Creative Commons license its photographer chose. Photographers keep their copyright unless the photo is CC0.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            let described = pack.species.filter { $0.descriptionSource != nil }.count
            if described > 0 {
                Text("Descriptions of \(described) species are adapted from English Wikipedia articles by Wikipedia contributors. Each species page in the pack links the article revision it came from.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Wikipedia text: CC BY-SA 4.0", destination: Self.wikipediaLicense)
                    .font(.footnote)
            }
            NavigationLink("Pack license (\(pack.info.id) v\(pack.info.version))", value: ContentView.Screen.packLicense)
        } header: {
            Text("Photos and text: \(pack.info.name)")
        }
        ForEach(pack.species) { species in
            Section(species.commonName) {
                ForEach(species.photos) { photo in
                    PhotoCreditRow(photo: photo)
                }
            }
        }
    }
}

/// One photo's observer, license (linked to its deed) and observation link.
private struct PhotoCreditRow: View {
    let photo: PackPhoto

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(photo.observer)
            if let licenseURL = photo.licenseURL {
                Link(photo.license, destination: licenseURL).font(.footnote)
            } else {
                Text(photo.license).font(.footnote).foregroundStyle(.secondary)
            }
            Link("Observation on iNaturalist", destination: photo.sourceURL)
                .font(.footnote)
        }
        .accessibilityElement(children: .combine)
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
            case .failure(let error):
                ContentUnavailableView("License not bundled", systemImage: "doc", description: Text(String(describing: error)))
            case nil:
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { text = Result(catching: load) }
    }
}
