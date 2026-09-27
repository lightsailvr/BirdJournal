import Pack
import SwiftUI

/// The bundled pack on the phone (issue #8): each species with its best photo and that photo's credit line, and a
/// detail page with every photo, credit and source link. The full credits screen with the model licenses is #11.
struct SpeciesPackView: View {
    var body: some View {
        switch BundledPack.loaded {
        case .success(let pack):
            SpeciesList(pack: pack)
        case .failure(let error):
            ContentUnavailableView("No species pack", systemImage: "bird", description: Text(String(describing: error)))
        }
    }
}

private struct SpeciesList: View {
    let pack: SpeciesPack

    var body: some View {
        List {
            Section {
                ForEach(pack.species) { species in
                    NavigationLink(value: ContentView.Screen.species(species)) {
                        SpeciesRow(pack: pack, species: species)
                    }
                }
            } footer: {
                Text("\(pack.species.count) species · \(pack.photos.count) photos from iNaturalist Open Data. Pack \(pack.info.id) v\(pack.info.version), built \(pack.info.builtAt).")
            }
        }
        .navigationTitle(pack.info.name)
    }
}

private struct SpeciesRow: View {
    let pack: SpeciesPack
    let species: PackSpecies

    var body: some View {
        HStack(spacing: 12) {
            PackImage(url: species.photos.first.map(pack.lensImageURL(for:)))
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(species.commonName)
                Text(species.scientificName)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
                Text(species.photos.first?.creditLine ?? "No photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// One species of the pack: every photo at phone size with its credit and observation link.
struct SpeciesDetailView: View {
    let pack: SpeciesPack
    let species: PackSpecies

    var body: some View {
        List {
            Section {
                LabeledContent("Scientific name", value: species.scientificName)
                LabeledContent("BirdNET label", value: species.birdnetLabel)
                if let url = species.wikipediaURL {
                    Link("Wikipedia", destination: url)
                }
            }
            ForEach(species.photos) { photo in
                Section {
                    PackImage(url: pack.phoneImageURL(for: photo))
                        .listRowInsets(EdgeInsets())
                    Text(photo.creditLine)
                        .font(.footnote)
                    Link("Observation on iNaturalist", destination: photo.sourceURL)
                        .font(.footnote)
                } header: {
                    Text(photo.rank == 0 ? "Best photo (shown on the lens)" : "Photo \(photo.rank + 1)")
                }
            }
        }
        .navigationTitle(species.commonName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A pack JPEG from disk; a placeholder when the pack has none or the file is missing.
private struct PackImage: View {
    let url: URL?

    var body: some View {
        if let url, let image = UIImage(contentsOfFile: url.path()) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(.secondarySystemFill)
                Image(systemName: "bird")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension PackSpecies: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
