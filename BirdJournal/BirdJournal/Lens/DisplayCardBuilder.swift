import CoreFoundation
import LensSession
import MWDATDisplay
import UIKit

// No SwiftUI import here: `Text`, `Button`, `Icon` and `Image` are the Display DSL, not SwiftUI's.

/// Maps one screenful of a `LensCard` one to one onto the single root `FlexBox` a Display send takes (DECISIONS.md,
/// "Toolkit facts"): one top-aligned column that fits the canvas (issue #24). Images are resolved by the caller:
/// the pure module names them, the pack (or the fake stack) holds the pixels. A photo the caller cannot load is
/// left out. Taps on the card's button and list rows are delivered to `onAction`.
enum DisplayCardBuilder {
    /// Padding around the card on the 600-pixel canvas; the pack's lens crops are cut to the width this leaves.
    static let padding: CGFloat = 24

    static func flexBox(
        for screenful: [LensElement],
        image: (LensImage) -> UIImage?,
        onAction: @escaping @Sendable (LensAction) -> Void
    ) -> FlexBox {
        // A photo the caller cannot load is left out, so the children are gathered before the builder runs.
        let children = screenful.compactMap { component($0, image: image, onAction: onAction) }
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
        case .meta(let text):
            return Text(text, style: .meta, color: .secondary)
        case .button(let button):
            return ButtonGroup {
                if button.isPrimary {
                    Button(label: button.label, style: .primary, iconName: .checkmark) { onAction(button.action) }
                        .actionRole(.primary)
                } else {
                    Button(label: button.label, style: .secondary) { onAction(button.action) }
                }
            }
        case .saved(let text):
            return FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                Icon(name: .checkmarkCircle, style: .filled)
                Text(text, style: .body)
            }
        case .list(let rows):
            return FlexBox(direction: .column, spacing: 8, crossAlignment: .stretch) {
                for row in rows {
                    Self.row(row, onAction: onAction)
                }
            }
        }
    }

    /// One tappable pill on the species list: name, match rate, and icons for a photo card and a saved sighting.
    private static func row(_ row: LensListRow, onAction: @escaping @Sendable (LensAction) -> Void) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            FlexBox(direction: .row) {
                Text(row.commonName, style: .body)
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
        .background(.card)
        .onTap { onAction(.open(index: row.index)) }
    }
}
