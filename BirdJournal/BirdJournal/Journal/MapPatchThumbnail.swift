import SwiftUI
import UIKit

/// A sighting's patch on the map (issue #150, A5): a flat picture in the edition's shape, tiny, with no shader under it. The painting
/// comes through `PatchTextures`, on its two-at-a-time decode queue, and the map holds only the small bitmap drawn from it, so a map
/// of thousands of sightings decodes each bird once. A bird with no painting on the phone is the edition's bare cloth and cord.
enum MapPatchThumbnail {
    /// The longest side of a patch on the map, and of the one the map was opened on.
    static let side: CGFloat = 38
    static let focusSide: CGFloat = 54
    /// Around the patch, for its shadow.
    static let room: CGFloat = 3

    /// The drawn pictures, by painting, edition and size.
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    /// The patch's rectangle inside a picture of `side`.
    static func patchRect(edition: PatchEdition, side: CGFloat) -> CGRect {
        let size = edition.aspect >= 1 ? CGSize(width: side, height: side / edition.aspect) : CGSize(width: side * edition.aspect, height: side)
        return CGRect(origin: CGPoint(x: room, y: room), size: size)
    }

    /// The patch drawn now: its painting, or the blank without one.
    static func draw(painting: CGImage?, edition: PatchEdition, side: CGFloat = side) -> UIImage {
        let rect = patchRect(edition: edition, side: side)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: rect.width + room * 2, height: rect.height + room * 2), format: format).image { context in
            let cg = context.cgContext
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            if let painting {
                UIImage(cgImage: painting).draw(in: rect)
            } else {
                let outline = PatchOutline(shape: edition.shape).path(in: rect.insetBy(dx: 1, dy: 1)).cgPath
                cg.addPath(outline)
                cg.setFillColor(UIColor(edition.twill).cgColor)
                cg.fillPath()
                cg.addPath(outline)
                cg.setStrokeColor(UIColor(edition.cord).cgColor)
                cg.setLineWidth(2)
                cg.strokePath()
            }
            cg.endTransparencyLayer()
        }
    }

    /// What can be shown at once: the finished picture if it's been drawn, else the blank.
    static func immediate(art: PatchArt?, edition: PatchEdition, side: CGFloat = side) -> UIImage {
        if let done = cache.object(forKey: key(art: art, edition: edition, side: side)) { return done }
        return blank(edition: edition, side: side)
    }

    private static func blank(edition: PatchEdition, side: CGFloat) -> UIImage {
        let cacheKey = key(art: nil, edition: edition, side: side)
        if let done = cache.object(forKey: cacheKey) { return done }
        let image = draw(painting: nil, edition: edition, side: side)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    /// The finished picture, decoding the painting if it must: the blank if there's none or it won't decode.
    static func load(art: PatchArt?, edition: PatchEdition, side: CGFloat = side) async -> UIImage {
        let cacheKey = key(art: art, edition: edition, side: side)
        if let done = cache.object(forKey: cacheKey) { return done }
        guard let art, let loaded = await PatchTextures.load(art, size: .thumbnail) else { return blank(edition: edition, side: side) }
        let image = draw(painting: loaded.colourBitmap, edition: edition, side: side)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    /// A patch standing for a cluster of sightings: the newest one's, with how many in the corner, in the place's tint.
    static func cluster(_ patch: UIImage, count: Int, tint: UIColor, ink: UIColor) -> UIImage {
        let text = NSAttributedString(string: count.formatted(), attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: ink,
        ])
        let textSize = text.size()
        let badge = CGSize(width: max(textSize.width + 10, 20), height: 20)
        let reach = badge.width * 0.45
        let size = CGSize(width: patch.size.width + reach, height: patch.size.height + badge.height * 0.3)
        return UIGraphicsImageRenderer(size: size).image { _ in
            patch.draw(at: CGPoint(x: 0, y: badge.height * 0.3))
            let frame = CGRect(x: size.width - badge.width, y: 0, width: badge.width, height: badge.height)
            tint.setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: badge.height / 2).fill()
            text.draw(at: CGPoint(x: frame.midX - textSize.width / 2, y: frame.midY - textSize.height / 2))
        }
    }

    private static func key(art: PatchArt?, edition: PatchEdition, side: CGFloat) -> NSString {
        "\(art?.colour.path(percentEncoded: false) ?? "blank")|\(edition.shape)|\(edition.twill)|\(side)" as NSString
    }
}
