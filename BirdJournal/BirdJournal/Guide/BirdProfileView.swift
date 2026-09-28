import Identification
import Pack
import SwiftUI

/// A bird's profile (issue #28): photo first with its credit, the names, a short introduction, the field marks, size
/// and habitat, the other photos, and the sources; sections the pack has no text for are left out rather than
/// filled. Reached from the guide, the journal and a candidate review (with `match`, the live detection).
struct BirdProfileView: View {
    @Environment(PackLibrary.self) private var library
    let scientificName: String
    let commonName: String
    var match: Candidate?

    var body: some View {
        let reference = library.species(scientificName: scientificName)
        PaperPage {
            VStack(alignment: .leading, spacing: 0) {
                Text(reference?.species.commonName ?? commonName)
                    .font(JournalFont.largeTitle)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                Text(scientificName)
                    .font(JournalFont.scientific)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.top, 2)

                if let match {
                    // No score in the headline: it lives in the "About this match" disclosure, explained.
                    Text("Heard \(match.windowsAboveThreshold)× this run")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 8)
                }

                if let reference {
                    ProfileContent(pack: reference.pack, species: reference.species, match: match)
                } else {
                    NameOnlyProfile(match: match)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfileContent: View {
    let pack: SpeciesPack
    let species: PackSpecies
    let match: Candidate?

    var body: some View {
        if let hero = species.photos.first {
            AttributedImage(pack: pack, photo: hero)
                .padding(.top, 16)
        }

        if let summary = species.summary, !summary.isEmpty {
            SectionTitle(text: "Get to know this bird")
            Text(summary)
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
                .padding(.top, 12)
        }

        let facts: [(String, String)] = [
            ("Look for", species.fieldMarks ?? ""),
            ("Size", species.size ?? ""),
            ("Often near", (species.habitat ?? "").capitalizedFirst),
        ].filter { !$0.1.isEmpty }
        if !facts.isEmpty {
            SectionTitle(text: "In the field")
            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.offset) { position, fact in
                    if position > 0 { RowRule() }
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(fact.0)
                            .font(JournalFont.body)
                            .foregroundStyle(Color.ink)
                            .frame(width: 92, alignment: .leading)
                        Text(fact.1)
                            .font(JournalFont.body)
                            .foregroundStyle(Color.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        }

        if let match {
            SectionTitle(text: "This detection")
            MatchDetails(candidate: match)
                .padding(.top, 8)
        }

        if species.photos.count > 1 {
            SectionTitle(text: "More photos")
            Text("Different birds, ages and lights; every photo is credited to the observer who took it.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 8)
            ForEach(species.photos.dropFirst()) { photo in
                AttributedImage(pack: pack, photo: photo)
                    .padding(.top, 16)
            }
        }

        SectionTitle(text: "Sources & credits")
        VStack(alignment: .leading, spacing: 10) {
            if species.descriptionSource != nil {
                Text("The text is adapted from the English Wikipedia article on this species, by Wikipedia contributors, under CC BY-SA 4.0.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
            Text("\(species.photos.count) \(species.photos.count == 1 ? "photo" : "photos") from iNaturalist observations, cropped for this app, each under the Creative Commons license its photographer chose.")
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
            NavigationLink(value: Route.speciesCredits(scientificName: species.scientificName)) {
                Label("Photo credits and sources", systemImage: "text.document")
            }
            .buttonStyle(.journalOutlined)
            if let wikipedia = species.wikipediaURL {
                Link(destination: wikipedia) {
                    Label("Read more on Wikipedia", systemImage: "arrow.up.right.square")
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.moss)
                }
            }
            Text("Powered by BirdNET")
                .font(JournalFont.attribution)
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.top, 12)
    }
}

/// A bird no installed pack describes: identifiable by name, nothing else to show.
private struct NameOnlyProfile: View {
    let match: Candidate?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "bird")
                .font(.system(size: 44))
                .foregroundStyle(Color.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
                .accessibilityHidden(true)
            Text("No photos or field notes for this bird are on your iPhone. BirdNET can still identify it by name; a bird pack that covers its region adds the rest.")
                .font(JournalFont.body)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            NavigationLink(value: Route.packs) {
                Label("Bird packs", systemImage: "square.stack.3d.down.right")
            }
            .buttonStyle(.journalOutlined)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        if let match {
            SectionTitle(text: "This detection")
            MatchDetails(candidate: match)
                .padding(.top, 8)
        }
    }
}
