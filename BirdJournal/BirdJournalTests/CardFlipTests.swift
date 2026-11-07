import Darwin
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #52, style guide "Card flip interaction": the card turns about its vertical axis with both faces mounted, one
// face showing at any point of the turn and never mirrored; Reduce Motion switches faces without turning.
@Suite("Card flip")
@MainActor
struct CardFlipTests {
    @Test("exactly one face shows at every point of the turn, the front up to halfway and the back from there")
    func oneFaceAtATime() {
        for angle in stride(from: 0.0, through: 180, by: 0.5) {
            let front = CardFlip.face(isBack: false, angle: angle, rotates: true)
            let back = CardFlip.face(isBack: true, angle: angle, rotates: true)
            #expect(front.opacity + back.opacity == 1, "angle \(angle)")
        }
        #expect(CardFlip.face(isBack: false, angle: 89.5, rotates: true).opacity == 1)
        #expect(CardFlip.face(isBack: true, angle: 90, rotates: true).opacity == 1)
    }

    @Test("each face reads the right way round when it is the one showing")
    func neverMirrored() {
        #expect(CardFlip.face(isBack: false, angle: 0, rotates: true).degrees == 0)
        #expect(CardFlip.face(isBack: true, angle: 180, rotates: true).degrees == 0)
        #expect(CardFlip.face(isBack: false, angle: 60, rotates: true).degrees == 60)
        #expect(CardFlip.face(isBack: true, angle: 120, rotates: true).degrees == -60)
    }

    @Test("with Reduce Motion nothing turns")
    func reduceMotion() {
        for angle in [0.0, 45, 90, 135, 180] {
            #expect(CardFlip.face(isBack: false, angle: angle, rotates: false).degrees == 0)
            #expect(CardFlip.face(isBack: true, angle: angle, rotates: false).degrees == 0)
        }
    }

    @Test("fading faces and external words never overlap, in either direction or on a reversed turn")
    func fadesNeverOverlap() {
        // The same curve drives Reduce Motion's card faces, the caption and the button's two labels.
        let forward = Array(stride(from: 0.0, through: 180, by: 0.5))
        for angle in forward + forward.reversed() + [40, 70, 85, 65, 90, 120, 105, 90, 60] {
            let front = CardFlip.face(isBack: false, angle: angle, rotates: false).opacity
            let back = CardFlip.face(isBack: true, angle: angle, rotates: false).opacity
            #expect((0...1).contains(front))
            #expect((0...1).contains(back))
            #expect(front == 0 || back == 0, "overlapping words at \(angle)°")
        }
        #expect(CardFlip.face(isBack: false, angle: 0, rotates: false).opacity == 1)
        #expect(CardFlip.face(isBack: true, angle: 180, rotates: false).opacity == 1)
        #expect(CardFlip.face(isBack: false, angle: 90, rotates: false).opacity == 0)
        #expect(CardFlip.face(isBack: true, angle: 90, rotates: false).opacity == 0)
    }
}

// What VoiceOver reaches: the card hosted in a window and its UIAccessibility tree walked the way VoiceOver walks it.
// XCUITest can't answer this: its tree lists elements SwiftUI hides from VoiceOver.
@Suite("Card flip accessibility")
@MainActor
struct CardFlipAccessibilityTests {
    /// SwiftUI builds its accessibility tree only for an assistive client; this switches app accessibility on in the
    /// test process, as accessibility snapshot tools do (test-only, never in the app).
    static func enableAccessibility() {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSApplicationAccessibilitySetEnabled")
        else { return }
        unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(true)
    }

    static func labels(showsBack: Bool, rotates: Bool = true) async throws -> [String] {
        try await labels(of: CollectibleCard(showsBack: showsBack, rotates: rotates) {
            VStack { Text("Front face"); Button("Front action") {} }
        } back: {
            VStack { Text("Back face"); Button("Back action") {} }
        })
    }

    static func labels(of view: some View) async throws -> [String] {
        enableAccessibility()
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))  // SwiftUI fills the accessibility tree after the first render
        return accessibleLabels(host.view)
    }

    /// The labels of the accessibility elements under `object`, skipping hidden subtrees.
    static func accessibleLabels(_ object: Any) -> [String] {
        guard let object = object as? NSObject, !object.accessibilityElementsHidden else { return [] }
        if object.isAccessibilityElement { return [object.accessibilityLabel ?? ""] }
        if let elements = object.accessibilityElements, !elements.isEmpty { return elements.flatMap(accessibleLabels) }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 { return (0..<count).compactMap { object.accessibilityElement(at: $0) }.flatMap(accessibleLabels) }
        if let view = object as? UIView { return view.subviews.flatMap(accessibleLabels) }
        return []
    }

    @Test("VoiceOver reaches only the face that is up, its controls included", arguments: [true, false])
    func oneFaceExposed(rotates: Bool) async throws {
        let front = try await Self.labels(showsBack: false, rotates: rotates)
        #expect(front.contains("Front face"), "\(front)")
        #expect(front.contains("Front action"))
        #expect(!front.contains("Back face"), "\(front)")
        #expect(!front.contains("Back action"))

        let back = try await Self.labels(showsBack: true, rotates: rotates)
        #expect(back.contains("Back face"), "\(back)")
        #expect(back.contains("Back action"))
        #expect(!back.contains("Front face"), "\(back)")
        #expect(!back.contains("Front action"))
    }

    @Test("the caption slot exposes only its selected words to VoiceOver", arguments: [true, false])
    func selectedWords(showsBack: Bool) async throws {
        let labels = try await Self.labels(of: CardFlipText(showsBack: showsBack) {
            Text("Patch caption")
        } back: {
            Text("Paper card caption")
        })
        #expect(labels == [showsBack ? "Paper card caption" : "Patch caption"], "\(labels)")
    }

    @Test("mid-turn, the face still in view but no longer up is already gone from VoiceOver, and the new one is there")
    func midTurn() async throws {
        // A tap on Flip from the front: at 45° the front still shows, but the back is the face that is up.
        let leaving = try await Self.labels(of: Text("Front face").modifier(FlipFace(angle: 45, isBack: false, isUp: false, rotates: true)))
        #expect(leaving.isEmpty, "\(leaving)")
        let arriving = try await Self.labels(of: Text("Back face").modifier(FlipFace(angle: 45, isBack: true, isUp: true, rotates: true)))
        #expect(arriving == ["Back face"], "\(arriving)")
    }
}
