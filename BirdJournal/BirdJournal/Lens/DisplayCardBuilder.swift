import CoreFoundation
import LensSession
import MWDATDisplay
import UIKit

// No SwiftUI import here: `Text`, `Button` and `Image` are the Display DSL, not SwiftUI's.

/// Maps a `LensCard` one to one onto the single root `FlexBox` a Display send takes (DECISIONS.md, "Toolkit facts").
/// Images are resolved by the caller: the pure module names them, the pack (or the fake stack) holds the pixels. A
/// photo the caller cannot load is left out and the card becomes a plain column.
enum DisplayCardBuilder {
    static func flexBox(
        for card: LensCard,
        image: (LensImage) -> UIImage?,
        onButton: @escaping @Sendable (LensButton) -> Void
    ) -> FlexBox {
        let column = FlexBox(direction: .column, spacing: 12) {
            for element in card.elements {
                component(element, onButton: onButton)
            }
        }
        guard let photo = card.photo.flatMap(image) else {
            return column
                .padding(24)
                .background(.card)
        }
        return FlexBox(direction: .row, spacing: 20, crossAlignment: .center) {
            // A bundled image is laid out at its pixel size, so the pack's lens crops decide the split.
            Image(image: photo, sizePreset: .fill, cornerRadius: .medium)
                .flexShrink(0)
            column
                .flexGrow(1)
                .flexShrink(1)
        }
        .padding(24)
        .background(.card)
        .alignSelf(.stretch)
    }

    private static func component(_ element: LensElement, onButton: @escaping @Sendable (LensButton) -> Void) -> any ViewComponent {
        switch element {
        case .heading(let text):
            return Text(text, style: .heading)
        case .body(let text):
            return Text(text, style: .body)
        case .meta(let text):
            return Text(text, style: .meta, color: .secondary)
        case .buttons(let buttons):
            return ButtonGroup {
                for button in buttons {
                    if button.isPrimary {
                        Button(label: button.label, style: .primary, iconName: .checkmark) { onButton(button.action) }
                            .actionRole(.primary)
                    } else {
                        Button(label: button.label, style: .secondary) { onButton(button.action) }
                    }
                }
            }
        }
    }
}
