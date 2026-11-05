import Album
import Pack
import SwiftUI

/// The share image (issue #136, guide 2.0 page 8): a composed object, never a screenshot. The patch at 1080 px on undyed
/// linen with its paper card tucked beneath, lit from a fixed upper-left light: an image has no tilt to follow. The card's
/// front says the name, the story title, the edition, the place the share may carry, the date, "AI illustration" and the
/// credits, with the Featherguild wordmark small. `CardExport` renders it; the renderer can't wait, so the patch's
/// textures come decoded, and without any it's the edition's blank.
struct PatchShareImage: View {
    /// What the card's front says: all of it is decided here, so the rules are tested without drawing.
    struct Facts: Equatable {
        var name: String
        /// The pack's reviewed story title; the app never invents one.
        var storyTitle: String?
        /// "Citrus edition · Pasadena · Nov 3, 2026".
        var line: String
        /// "AI illustration · Featherguild", the wordmark small.
        var imprint: String
        /// "Patch from a reference photo: © Name (CC BY). Story text: CC BY-SA 4.0."; nil when nothing needs crediting.
        var credits: String?
    }

    /// The patch's longest side on the image, in points: 1080 px at `CardExport.imageScale`, from the pack's 720 px painting.
    static let patchWidth: CGFloat = 240
    /// Upper-left, where the light rests on a phone and stays under Reduce Motion.
    static let light = PatchLightModel.rest

    let facts: Facts
    let edition: PatchEdition
    let loaded: PatchTextures.Loaded?

    var body: some View {
        VStack(spacing: -34) {
            patch
                .frame(width: Self.patchWidth, height: Self.patchWidth / max(edition.aspect, 1))
                .zIndex(1)
            card
                .rotationEffect(.degrees(-2.5))
                .padding(.horizontal, 30)
        }
        .padding(.top, 42)
        .padding(.bottom, 46)
        .frame(width: 360)
        .background {
            Image("MaterialLinen")
                .resizable(resizingMode: .tile)
        }
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
    }

    @ViewBuilder private var patch: some View {
        Color.clear
            .aspectRatio(edition.aspect, contentMode: .fit)
            .overlay {
                if let loaded {
                    LitPatch(loaded: loaded, ground: edition.twill, sewnTo: StitchTimeline.allSewn, room: 34, fixedLight: Self.light)
                } else {
                    PatchBlank(edition: edition)
                }
            }
    }

    private var card: some View {
        VStack(spacing: 4) {
            Text(facts.name)
                .font(.system(.title2, design: .serif, weight: .semibold))
                .foregroundStyle(Color.cardInk)
            if let title = facts.storyTitle {
                Text(title)
                    // In italic under the name, as guide page 8 sets it on this card.
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(Color.cardInk)
            }
            Text(facts.line)
                .font(CardFont.credit)
                .foregroundStyle(Color.cardInkSecondary)
                .padding(.top, 6)
            Text(facts.imprint)
                .font(CardFont.credit)
                .foregroundStyle(Color.cardInkSecondary)
            if let credits = facts.credits {
                Text(credits)
                    // Fixed: this is a picture at a fixed type size, and 8 pt comes to 36 px on it.
                    .font(.system(size: 8))
                    .foregroundStyle(Color.cardInkSecondary)
                    .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 54)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .modifier(CardStockSurface())
    }
}

extension PatchShareImage.Facts {
    /// - Parameters:
    ///   - place: only what the share may carry: a city, "a secret spot", or nothing when the city is off
    ///     (`FindPolicy.sharedPlace`).
    ///   - hasPainting: whether the patch is painted; a blank isn't an illustration, and has no credit but the story's.
    init(sighting: Sighting, name: String, placement: CardPlacement?, place: String?, lore: PackLore?, hasPainting: Bool, photoCredits: [String]) {
        let date = sighting.confirmedAt.formatted(date: .abbreviated, time: .omitted)
        self.name = name
        storyTitle = lore?.title?.nilIfEmpty
        line = [placement?.editionLabel, place, date].compactMap { $0 }.joined(separator: " · ")
        imprint = hasPainting ? "AI illustration · Featherguild" : "Featherguild"
        var credits: [String] = []
        if !photoCredits.isEmpty { credits.append("Patch from a reference photo: \(photoCredits.joined(separator: "; ")).") }
        if storyTitle != nil { credits.append("Story text: CC BY-SA 4.0.") }
        self.credits = credits.isEmpty ? nil : credits.joined(separator: " ")
    }

    /// Who took the photos the patch's bird was stitched from, as iNaturalist credits them.
    static func credits(of patch: PackPatch, in species: PackSpecies) -> [String] {
        patch.sourcePhotoIDs.compactMap { id in species.photos.first { $0.inatPhotoID == id }?.creditLine }
    }
}
