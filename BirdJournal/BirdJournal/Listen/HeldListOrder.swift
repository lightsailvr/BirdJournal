import Foundation
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// The order a run's rows are shown in, which holds still around a touch (the maintainer, issue #150): from a finger coming down
/// on the list, while it scrolls, or while VoiceOver's focus is on a row, until `settle` seconds after the last of those ends. A
/// live list re-sorts as birds call, and a row moving under a thumb adds the wrong bird. A bird first heard during a hold goes at
/// the bottom, where it moves nothing, so a new patch still shows at once; the next re-sort puts it in its place. Only the order
/// holds: a row's own contents keep updating.
struct HeldListOrder<ID: Hashable>: Equatable {
    /// What's holding the list.
    enum Holder: Hashable {
        case finger
        case scroll
        case voiceOverFocus(ID)

        var isVoiceOverFocus: Bool {
            if case .voiceOverFocus = self { true } else { false }
        }
    }

    static var settle: TimeInterval { 1.5 }
    /// The last resort for a finger or scroll that never said it ended, however that came about. Long, because a finger can
    /// really stay still. VoiceOver's focus can stay as long as it likes, so this leaves it alone.
    static var staleAfter: TimeInterval { 20 }

    private var holders: Set<Holder> = []
    private var lastTouch: Date?
    private var frozen: [ID]?
    /// When the hold began, for whatever else above the rows must hold still with it; nil when it isn't holding.
    private(set) var frozenAt: Date?
    /// When the list can move again, once nothing holds it; nil while something does.
    private(set) var releaseAt: Date?

    var isHeld: Bool { frozen != nil }

    /// What to show for the order the coordinator has now.
    func shown(_ order: [ID]) -> [ID] {
        guard let frozen else { return order }
        let current = Set(order)
        let kept = frozen.filter(current.contains)
        let held = Set(kept)
        return kept + order.filter { !held.contains($0) }
    }

    /// Something starts holding the list, whose order is `order` now.
    mutating func hold(_ holder: Holder, showing order: [ID], at now: Date) {
        if frozen == nil {
            frozen = order
            frozenAt = now
        }
        // Not every report: a finger moving reports at the display's rate, and each change here redraws the list.
        if lastTouch.map({ now.timeIntervalSince($0) >= 5 }) ?? true { lastTouch = now }
        holders.insert(holder)
        releaseAt = nil
    }

    /// Something stops holding it. The list moves `settle` seconds after the last of them.
    mutating func letGo(_ holder: Holder, at now: Date) {
        holders.remove(holder)
        if holders.isEmpty, frozen != nil { releaseAt = now.addingTimeInterval(Self.settle) }
    }

    /// The list has left the screen, a sheet has covered it or the phone has locked: whatever was holding it may never say it
    /// ended. A flick still decelerating when another tab opens doesn't.
    mutating func letGoOfEverything(at now: Date) {
        holders = []
        if frozen != nil { releaseAt = now.addingTimeInterval(Self.settle) }
    }

    /// During a hold, birds new to the order keep the place they were first shown in, whatever the order does with them later.
    mutating func take(_ order: [ID]) {
        guard frozen != nil else { return }
        frozen = shown(order)
    }

    /// The clock's turn: the list is let go once it's due.
    /// - Parameter isVoiceOverRunning: turned off with its focus on a row, VoiceOver won't say the focus has gone.
    mutating func tick(at now: Date, isVoiceOverRunning: Bool = true) {
        if !isVoiceOverRunning, holders.contains(where: \.isVoiceOverFocus) {
            holders = holders.filter { !$0.isVoiceOverFocus }
            if holders.isEmpty { releaseAt = now }
        }
        if !holders.isEmpty, let lastTouch, now.timeIntervalSince(lastTouch) >= Self.staleAfter {
            holders = holders.filter(\.isVoiceOverFocus)
            if holders.isEmpty { releaseAt = now }
        }
        guard holders.isEmpty, let releaseAt, now >= releaseAt else { return }
        frozen = nil
        frozenAt = nil
        lastTouch = nil
        self.releaseAt = nil
    }
}

/// Says when a finger is down on a view, and leaves the touch to everything else: the row's buttons, and the scroll view.
struct FingerDown: UIGestureRecognizerRepresentable {
    let changed: (Bool) -> Void

    final class Recognizer: UIGestureRecognizer {
        private var fingers = 0

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            fingers += touches.count
            state = state == .possible ? .began : .changed
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .changed
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            fingers -= touches.count
            state = fingers > 0 ? .changed : .ended
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            fingers -= touches.count
            state = fingers > 0 ? .changed : .cancelled
        }

        override func reset() {
            fingers = 0
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer(target: nil, action: nil)
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: changed(true)
        case .ended, .cancelled, .failed: changed(false)
        default: break
        }
    }
}
