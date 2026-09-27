import CoreFoundation
import LensSession
import MWDATDisplay
import UIKit

// No SwiftUI import here: `Text`, `Button` and `Image` are the Display DSL, not SwiftUI's.

/// Maps a `LensCard` one to one onto the single root `FlexBox` a Display send takes (DECISIONS.md, "Toolkit facts").
/// Images are resolved by the caller: the pure module names them, the pack (or the fake stack) holds the pixels.
enum DisplayCardBuilder {
    static func flexBox(
        for card: LensCard,
        image: (LensImage) -> UIImage?,
        onButton: @escaping @Sendable (LensButton) -> Void
    ) -> FlexBox {
        switch card.layout {
        case .column:
            return FlexBox(direction: .column, spacing: 12) {
                for element in card.elements {
                    component(element, image: image, onButton: onButton)
                }
            }
            .padding(24)
            .background(.card)

        case .photoBeside:
            var elements = card.elements
            let photo: UIImage? = if case .image(let ref)? = elements.first { image(ref) } else { nil }
            if photo != nil { elements.removeFirst() }
            return FlexBox(direction: .row, spacing: 20, crossAlignment: .center) {
                if let photo {
                    // A bundled image is laid out at its pixel size, so the pack's lens crops decide the split.
                    Image(image: photo, sizePreset: .fill, cornerRadius: .medium)
                        .flexShrink(0)
                }
                FlexBox(direction: .column, spacing: 12) {
                    for element in elements {
                        component(element, image: image, onButton: onButton)
                    }
                }
                .flexGrow(1)
                .flexShrink(1)
            }
            .padding(24)
            .background(.card)
            .alignSelf(.stretch)
        }
    }

    private static func component(
        _ element: LensElement,
        image: (LensImage) -> UIImage?,
        onButton: @escaping @Sendable (LensButton) -> Void
    ) -> any ViewComponent {
        switch element {
        case .heading(let text):
            return Text(text, style: .heading)
        case .body(let text):
            return Text(text, style: .body)
        case .meta(let text):
            return Text(text, style: .meta, color: .secondary)
        case .image(let ref):
            guard let uiImage = image(ref) else { return Text("No photo", style: .meta, color: .secondary) }
            return Image(image: uiImage, sizePreset: .fill, cornerRadius: .medium)
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
