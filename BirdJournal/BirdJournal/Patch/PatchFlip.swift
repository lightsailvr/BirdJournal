import SwiftUI

/// The flip (issue #134, guide page 10; #52's real turn): the object turns about its vertical centre in about 600 ms with
/// both faces mounted, each showing only on its half of the turn and never mirrored. Under Reduce Motion nothing turns:
/// the outgoing face fades completely away before the incoming one appears.
enum CardFlip {
    static let duration = 0.6
    static let crossFade = 0.25

    /// One face at `angle` degrees of the turn (0 front up, 180 back up): how far it is turned and how opaque.
    static func face(isBack: Bool, angle: Double, rotates: Bool) -> (degrees: Double, opacity: Double) {
        guard rotates else {
            let progress = min(max(angle / 180, 0), 1)
            return (0, isBack ? max(0, 2 * progress - 1) : max(0, 1 - 2 * progress))
        }
        let isVisible = isBack ? angle >= 90 : angle < 90
        return (isBack ? angle - 180 : angle, isVisible ? 1 : 0)
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeInOut(duration: crossFade) : .easeInOut(duration: duration)
    }
}

/// Words outside the turning card share its progress, but never rotate. Both alternatives keep one stable slot;
/// the split opacity guarantees they cannot overlap, including when a quick second tap reverses the turn.
/// Only the selected words enter the accessibility tree, just like the card's selected face.
struct CardFlipText<Front: View, Back: View>: View {
    let showsBack: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back

    var body: some View {
        let angle = showsBack ? 180.0 : 0
        ZStack {
            front.modifier(FlipFace(angle: angle, isBack: false, isUp: !showsBack, rotates: false))
            back.modifier(FlipFace(angle: angle, isBack: true, isUp: showsBack, rotates: false))
        }
    }
}

/// Both faces of one object in one footprint: the front's. The back takes the same size and scrolls inside it, so the turn
/// keeps its shape; with `backGrows` (accessibility text sizes) the back takes the height it needs and the page scrolls
/// instead, since lore is never shrunk to keep the shape. Only the readable face reaches VoiceOver and touches.
struct CollectibleCard<Front: View, Back: View>: View {
    let showsBack: Bool
    let rotates: Bool
    var backGrows = false
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back
    @State private var frontHeight: CGFloat?

    var body: some View {
        let angle = showsBack ? 180.0 : 0
        ZStack(alignment: .top) {
            front
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { frontHeight = $0 }
                .modifier(FlipFace(angle: angle, isBack: false, isUp: !showsBack, rotates: rotates))
            // Zero until the front is measured: the back's scroll view would otherwise take its whole content's height.
            back
                .frame(height: backGrows && showsBack ? nil : frontHeight ?? 0, alignment: .top)
                .clipped()
                .modifier(FlipFace(angle: angle, isBack: true, isUp: showsBack, rotates: rotates))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rotates ? "card-rotates" : "card-switches")
    }
}

/// One face at a point of the turn, animated through `angle`. Whether it is up comes from the state, not the turn: the
/// face that is up is the one VoiceOver reads and touches reach (`CardFlipAccessibilityTests` walks the tree VoiceOver
/// sees; XCUITest's tree still lists the hidden face, so the UI tests can't check this).
struct FlipFace: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool
    let isUp: Bool
    let rotates: Bool

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let face = CardFlip.face(isBack: isBack, angle: angle, rotates: rotates)
        content
            // A container first (issue #119): `.accessibilityHidden(false)` straight on the face that is up re-exposed the
            // decorations inside it that hide themselves, as empty VoiceOver stops. As a container the face keeps their
            // hiding and still hides whole when it isn't up.
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!isUp)
            .allowsHitTesting(isUp)
            .rotation3DEffect(.degrees(face.degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .opacity(face.opacity)
    }
}
