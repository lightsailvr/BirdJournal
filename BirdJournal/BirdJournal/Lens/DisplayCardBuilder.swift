import Album
import CoreFoundation
import LensSession
import MWDATDisplay
import UIKit

// No SwiftUI import here: `Text`, `Button`, `Icon` and `Image` are the Display DSL, not SwiftUI's.

/// Maps a `LensCard` one to one onto the single root `FlexBox` a Display send takes (DECISIONS.md, "Toolkit facts"):
/// one top-aligned column that the glasses scroll vertically (issue #24). Images are resolved by the caller: the
/// pure module names them, the pack (or the fake stack) holds the pixels. A photo the caller cannot load is left
/// out. Taps on the card's button are delivered to `onAction`; list rows are not tappable, the app moves their
/// selection itself from Inputs. The viewfinder shows `viewfinder`, the camera's latest frame already sized for the
/// lens, or says it is waiting for one. "Say the bird's name" (issue #194) shows `capturedPhoto`, the picture just
/// taken, small, and is drawn without it when there is none; the rows a photo is named from are drawn like the list's.
enum DisplayCardBuilder {
    /// Padding around the card on the 600-pixel canvas; the pack's lens crops are cut to the width this leaves.
    nonisolated static let padding: CGFloat = 24
    /// The box a viewfinder frame is scaled to fit: the card's width, and the height the name and hint leave.
    nonisolated static let viewfinderSize = CGSize(width: 600 - 2 * padding, height: 420)
    /// The box the photo on "Say the bird's name" is scaled to fit: a thumbnail, with room under it for the words heard.
    nonisolated static let capturedPhotoSize = CGSize(width: 600 - 2 * padding, height: 260)

    static func flexBox(
        for card: LensCard,
        image: (LensImage) -> UIImage?,
        viewfinder: UIImage? = nil,
        capturedPhoto: UIImage? = nil,
        onAction: @escaping @Sendable (LensAction) -> Void
    ) -> FlexBox {
        // A photo the caller cannot load is left out, so the children are gathered before the builder runs.
        let children = card.elements.compactMap { component($0, image: image, viewfinder: viewfinder, capturedPhoto: capturedPhoto, onAction: onAction) }
        return FlexBox(direction: .column, spacing: 12, crossAlignment: .stretch) {
            for child in children {
                child
            }
        }
        .padding(padding)
        .background(.card)
        .alignSelf(.stretch)
    }

    private static func component(
        _ element: LensElement,
        image: (LensImage) -> UIImage?,
        viewfinder: UIImage?,
        capturedPhoto: UIImage?,
        onAction: @escaping @Sendable (LensAction) -> Void
    ) -> (any ViewComponent)? {
        switch element {
        case .status(let text):
            return Text(text, style: .meta, color: .secondary)
        case .photo(let photo):
            // A bundled image is laid out at its pixel size: the pack cuts lens crops to the card's width.
            guard let loaded = image(photo) else { return nil }
            return FlexBox(direction: .row) {
                Image(image: loaded, sizePreset: .fill, cornerRadius: .medium)
            }
            .alignSelf(.start)
        case .title(let name, let detail):
            return FlexBox(direction: .row, spacing: 12, crossAlignment: .end) {
                Text(name, style: .heading)
                Text(detail, style: .meta, color: .secondary)
            }
        case .heading(let text):
            return Text(text, style: .heading)
        case .body(let text):
            return Text(text, style: .body)
        case .passage(let text):
            return Text(text, style: .meta, color: .primary)
        case .meta(let text):
            return Text(text, style: .meta, color: .secondary)
        case .button(let button):
            return ButtonGroup {
                Button(label: button.label, style: .primary, iconName: .checkmark) { onAction(button.action) }
                    .actionRole(.primary)
            }
        case .saved(let text):
            return FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                Icon(name: .checkmarkCircle, style: .filled)
                Text(text, style: .body)
            }
        case .capture(let label, let isSelected):
            return captureRow(label, isSelected: isSelected)
        case .list(let rows):
            return FlexBox(direction: .column, spacing: 8, crossAlignment: .stretch) {
                for row in rows {
                    Self.row(row, onAction: onAction)
                }
            }
        case .sounds(let rows):
            return FlexBox(direction: .column, spacing: 8, crossAlignment: .stretch) {
                for row in rows {
                    Self.soundRow(row)
                }
            }
        case .viewfinder:
            guard let viewfinder else {
                return Text("Waiting for the camera…", style: .body, color: .secondary)
            }
            return FlexBox(direction: .row) {
                Image(image: viewfinder, sizePreset: .fill, cornerRadius: .medium)
            }
            .alignSelf(.center)
        case .capturedPhoto:
            guard let capturedPhoto else { return nil }
            return FlexBox(direction: .row) {
                Image(image: capturedPhoto, sizePreset: .fill, cornerRadius: .medium)
            }
            .alignSelf(.center)
        case .choices(let rows):
            return FlexBox(direction: .column, spacing: 8, crossAlignment: .stretch) {
                for row in rows {
                    Self.choiceRow(row)
                }
            }
        }
    }

    /// The photo just taken, scaled down to fit `capturedPhotoSize` and cropped as the journal will show it
    /// (`FrameCrop.albumZoom`): a bundled image is laid out at its pixel size, and the send carries no more than the lens
    /// shows. Nil for data that is no picture. Safe to call off the main actor.
    nonisolated static func capturedPhotoImage(_ photo: Data) -> UIImage? {
        guard let image = UIImage(data: photo), image.size.width > 0, image.size.height > 0 else { return nil }
        let crop = FrameCrop.centerRect(in: image.size)
        let scale = min(capturedPhotoSize.width / crop.width, capturedPhotoSize.height / crop.height, 1)
        let size = CGSize(width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: image.size.width * scale, height: image.size.height * scale))
        }
    }

    /// One row a photo is named from (issue #194), marked like a list row: a caret and a card background on the
    /// highlighted one; a bird's name, with "New patch" beside it when the naming would sew one, or one of the two ways on.
    private static func choiceRow(_ row: LensChoiceRow) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            if row.isSelected {
                Icon(name: .caretRight, style: .filled)
            }
            FlexBox(direction: .row) {
                Text(row.label, style: .body, color: row.isSelected ? .primary : .secondary)
            }
            .flexGrow(1)
            .flexShrink(1)
            if let detail = row.detail {
                Text(detail, style: .meta, color: .secondary)
            }
        }
        .padding(EdgeInsets(top: 8, bottom: 8, leading: 12, trailing: 12))
        .background(row.isSelected ? .card : .none)
    }

    /// The camera frame scaled down to fit `viewfinderSize`, so the send carries no more pixels than the lens shows,
    /// with the album's crop marked: outside it dimmed, a frame around it, so the wearer composes the picture the
    /// journal will show (`FrameCrop.albumZoom`). Safe to call off the main actor.
    nonisolated static func viewfinderImage(_ frame: UIImage) -> UIImage {
        let scale = min(viewfinderSize.width / frame.size.width, viewfinderSize.height / frame.size.height, 1)
        let size = CGSize(width: (frame.size.width * scale).rounded(), height: (frame.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            frame.draw(in: bounds)
            let crop = FrameCrop.centerRect(in: size)
            let cg = context.cgContext
            cg.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            cg.addRect(bounds)
            cg.addRect(crop)
            cg.fillPath(using: .evenOdd)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(3)
            cg.stroke(crop.insetBy(dx: 1.5, dy: 1.5))
        }
    }

    /// One clip on the sounds page, marked like a list row: a caret on the clip a tap plays next, a speaker on the one
    /// playing.
    private static func soundRow(_ row: LensSoundRow) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            if row.isNext {
                Icon(name: .caretRight, style: .filled)
            }
            if row.isPlaying {
                Icon(name: .speakerWithThreeArcs, style: .filled)
            }
            Text(row.label, style: .body, color: row.isNext || row.isPlaying ? .primary : .secondary)
        }
        .padding(EdgeInsets(top: 8, bottom: 8, leading: 12, trailing: 12))
        .background(row.isNext || row.isPlaying ? .card : .none)
    }

    /// The "Capture a sighting" row above the birds (issue #193), marked like a bird's row when the highlight is on it:
    /// a caret and a card background; a viewfinder's corners before the words tell it from a bird.
    private static func captureRow(_ label: String, isSelected: Bool) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            if isSelected {
                Icon(name: .caretRight, style: .filled)
            }
            Icon(name: .fourCornerFrame, style: .outline)
            Text(label, style: .body, color: isSelected ? .primary : .secondary)
        }
        .padding(EdgeInsets(top: 8, bottom: 8, leading: 12, trailing: 12))
        .background(isSelected ? .card : .none)
    }

    /// One row of the species list: a caret and a card background mark the selected row; a speaker before the name
    /// and the primary colour mark a bird calling now (issue #42), so the two can coincide; name, match rate, and
    /// icons for a photo card and a saved sighting.
    private static func row(_ row: LensListRow, onAction: @escaping @Sendable (LensAction) -> Void) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            if row.isSelected {
                Icon(name: .caretRight, style: .filled)
            }
            if row.isCalling {
                Icon(name: .speakerWithThreeArcs, style: .filled)
            }
            FlexBox(direction: .row) {
                Text(row.commonName, style: .body, color: row.isSelected || row.isCalling ? .primary : .secondary)
            }
            .flexGrow(1)
            .flexShrink(1)
            Text(row.confidence, style: .meta, color: .secondary)
            if row.hasPhoto {
                Icon(name: .mountainSquare, style: .outline)
            }
            if row.isSaved {
                Icon(name: .checkmarkCircle, style: .filled)
            }
        }
        .padding(EdgeInsets(top: 8, bottom: 8, leading: 12, trailing: 12))
        .background(row.isSelected ? .card : .none)
    }
}
