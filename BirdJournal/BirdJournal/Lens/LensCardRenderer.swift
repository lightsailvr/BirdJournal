import CoreFoundation
import LensSession
import MWDATDisplay

// No SwiftUI import here: `Text` and `Button` are the Display DSL, not SwiftUI's.

/// Turns a `LensCard` into the one root `FlexBox` a Display send takes (DECISIONS.md, "Toolkit facts").
enum LensCardRenderer {
    static func render(_ card: LensCard, onButton: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 12) {
            Text(card.heading, style: .heading)
            Text(card.body, style: .body, color: .secondary)
            Button(label: card.buttonLabel, style: .primary, onClick: onButton)
        }
        .padding(24)
        .background(.card)
    }
}
