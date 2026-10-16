import Album
import Pack
import SwiftUI

/// The collectible cards' tokens (issue #51, collectible-cards style guide v0.2). Gold marks a first discovery, never
/// rarity, and always comes with words. The card face is a fixed illustrated surface, evergreen with warm ivory text,
/// the same in both appearances, since art is never recoloured for dark mode.
extension Color {
    /// Gold text and marks on the paper.
    static let goldInk = Color("CollectibleGoldInk")
    /// The quiet gold ground of a first-discovery moment.
    static let goldWash = Color("CollectibleGoldWash")
    /// The frame of a card that is not Legendary.
    static let editionSage = Color("CollectibleSage")
    /// The card face: evergreen, fixed in both appearances.
    static let cardFace = Color(red: 0x15 / 255, green: 0x2D / 255, blue: 0x26 / 255)
    /// Text on the card face: warm ivory (13:1 on the face).
    static let cardIvory = Color(red: 0xFF / 255, green: 0xF3 / 255, blue: 0xCE / 255)
    /// The Legendary label on the card face (10:1 on the face).
    static let cardGold = Color(red: 0xED / 255, green: 0xD4 / 255, blue: 0x97 / 255)
}

enum CollectibleLayout {
    /// The card's corner radius.
    static let cardRadius: CGFloat = 18
    /// The art's shape on a card: portrait, as pack art will be.
    static let artAspectRatio: CGFloat = 3 / 4
}

/// The Legendary frame's foil: four golds blended around the card.
extension ShapeStyle where Self == AngularGradient {
    static var legendaryFoil: AngularGradient {
        AngularGradient(
            colors: [0xEDD497, 0x887342, 0xE2CF92, 0xAA8C45, 0xEDD497].map { hex in
                Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
            },
            center: .center
        )
    }
}

/// "Legendary · Your first" with its sparkle, on the card face. The sparkle is decoration; the words carry it.
struct LegendaryLabel: View {
    var body: some View {
        Label {
            Text("Legendary · Your first")
        } icon: {
            Image(systemName: "sparkles")
                .accessibilityHidden(true)
        }
        .font(JournalFont.attribution.weight(.semibold))
        .foregroundStyle(Color.cardGold)
    }
}

/// One card of the collection (issue #51): the Legendary label on the birder's first of a species, the art, the
/// species and the date and method, on the card face inside a gold frame when Legendary and a sage one otherwise.
/// Until pack art arrives the art is the glasses photo, else the pack's reference photo, labelled as such.
struct CardTile: View {
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    let isLegendary: Bool

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        VStack(alignment: .leading, spacing: 8) {
            if isLegendary {
                LegendaryLabel()
            }
            CardArtView(sighting: sighting, reference: reference, commonName: library.commonName(for: sighting))
            VStack(alignment: .leading, spacing: 2) {
                Text(library.commonName(for: sighting))
                    .font(JournalFont.heading)
                    .foregroundStyle(Color.cardIvory)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(sighting.confirmedAt.formatted(date: .abbreviated, time: .omitted)) · \(sighting.method.title)")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.cardIvory.opacity(0.8))
            }
        }
        .modifier(TileFrame(isLegendary: isLegendary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        [
            library.commonName(for: sighting),
            isLegendary ? "Legendary, your first" : nil,
            sighting.confirmedAt.formatted(date: .long, time: .shortened),
            sighting.method.title,
            CardArtView.art(for: sighting, reference: library.species(scientificName: sighting.scientificName)).label,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// A grid tile's card face: the evergreen face in a gold frame when Legendary, a sage one otherwise, and a moss ring
/// around it when it is the card last opened from a gallery. A gallery's tiles (`isSelected` set) keep room for the
/// ring whether or not it shows, so every tile is the same size.
private struct TileFrame: ViewModifier {
    let isLegendary: Bool
    var isSelected: Bool?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius, style: .continuous)
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.cardFace, in: shape)
            .overlay {
                shape.strokeBorder(isLegendary ? AnyShapeStyle(.legendaryFoil) : AnyShapeStyle(Color.editionSage), lineWidth: isLegendary ? 4 : 2)
            }
            .padding(isSelected == nil ? 0 : 4)
            .overlay {
                if isSelected == true {
                    RoundedRectangle(cornerRadius: CollectibleLayout.cardRadius + 4, style: .continuous)
                        .strokeBorder(Color.moss, lineWidth: 3)
                }
            }
            .contentShape(shape)
    }
}

/// One tile of a species gallery (issue #53): the Legendary label on the birder's first (set editions wait for pack
/// schema 4), the art, and what tells two cards of one bird apart: the place, the date and time, and Heard or Seen.
struct GalleryTile: View {
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    /// The gallery's place for the card, nil for "Place not recorded".
    let place: String?
    let isLegendary: Bool
    let isSelected: Bool

    var body: some View {
        let reference = library.species(scientificName: sighting.scientificName)
        VStack(alignment: .leading, spacing: 8) {
            if isLegendary {
                LegendaryLabel()
            }
            CardArtView(sighting: sighting, reference: reference, commonName: library.commonName(for: sighting))
            VStack(alignment: .leading, spacing: 2) {
                Text(place ?? SpeciesGallery.PlaceFilter.notRecorded.title)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.cardIvory)
                Text(sighting.confirmedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.cardIvory.opacity(0.8))
                Text("\(sighting.confirmedAt.formatted(date: .omitted, time: .shortened)) · \(sighting.method.title)")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.cardIvory.opacity(0.8))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(TileFrame(isLegendary: isLegendary, isSelected: isSelected))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        [
            place ?? SpeciesGallery.PlaceFilter.notRecorded.title,
            sighting.confirmedAt.formatted(date: .long, time: .shortened),
            sighting.method.title,
            isLegendary ? "Legendary, your first" : nil,
            CardArtView.art(for: sighting, reference: library.species(scientificName: sighting.scientificName)).label,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// A card's art for now: the glasses photo at the album's crop, else the pack's reference photo, each labelled, so a
/// reference photo is never taken for the birder's own; with neither, a typographic face naming the bird (issue #52).
struct CardArtView: View {
    let sighting: Sighting
    let reference: (pack: SpeciesPack, species: PackSpecies)?
    let commonName: String

    /// What the art is.
    static func art(for sighting: Sighting, reference: (pack: SpeciesPack, species: PackSpecies)?) -> CardText.Art {
        CardText.Art(sighting: sighting, referenceCredit: reference?.species.photos.first?.creditLine)
    }

    var body: some View {
        let art = Self.art(for: sighting, reference: reference)
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(CollectibleLayout.artAspectRatio, contentMode: .fit)
                .overlay {
                    switch art {
                    case .glassesPhoto(let path):
                        FrameImage(frameImagePath: path)
                    case .referencePhoto:
                        PackImage(url: reference.flatMap { found in found.species.photos.first.map(found.pack.phoneImageURL(for:)) })
                    case .none:
                        TypographicArt(commonName: commonName)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: JournalLayout.thumbnailRadius, style: .continuous))
                .accessibilityHidden(true)
            Text(art.label)
                .font(JournalFont.attribution)
                .foregroundStyle(Color.cardIvory.opacity(0.8))
        }
    }
}

/// The missing-art face: the bird's name set large on the card's own colours, so the card reads as unfinished rather
/// than broken.
private struct TypographicArt: View {
    let commonName: String

    var body: some View {
        Color.cardIvory.opacity(0.08)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "bird")
                        .font(.title)
                    Text(commonName)
                        .font(JournalFont.title)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                }
                .foregroundStyle(Color.cardIvory.opacity(0.7))
                .padding(12)
            }
    }
}
