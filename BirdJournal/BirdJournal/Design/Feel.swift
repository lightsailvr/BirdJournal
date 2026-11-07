import SwiftUI

/// What the app's haptics mean (issue #150, audit R3), named here and nowhere else, and played only through `.haptic(_:trigger:)`,
/// so they stay consistent. They all go through `sensoryFeedback`, so the system's haptics setting turns them off.
///
/// A phone-microphone run keeps the audio session recording, and `AVAudioSession` would silence these during it, so
/// `PhoneMicAudioSource` allows them. Whether a stitch's ticks then reach the microphone as false detections is for a phone:
/// `ticksDuringPhoneRun` is the switch, and DECISIONS.md has the rest.
enum Haptic: String, CaseIterable, Sendable {
    /// A patch's page opening. The touch itself is the press's: a touch can also be the start of a scroll.
    case lift
    /// A patch going over to its paper card, or back.
    case turn
    /// One stitch of a count rising or thread advancing.
    case stitchTick
    /// The last stitch: the new patch is finished.
    case stitchDone
    /// A run starting or stopping.
    case startStop
    /// A reaction given.
    case reaction
    /// Something the birder asked for failed.
    case error

    var feedback: SensoryFeedback {
        switch self {
        case .lift: .impact(flexibility: .soft)
        case .turn: .impact(weight: .light)
        case .stitchTick: .selection
        case .stitchDone: .success
        case .startStop: .impact(weight: .medium)
        case .reaction: .impact(weight: .light)
        case .error: .error
        }
    }

    /// Whether a stitch ticks while the phone's microphone is listening. On, as the issue has it, until a phone says otherwise. If
    /// ticks raise false detections, this goes false and everything else still plays, Start and Stop included.
    static let ticksDuringPhoneRun = true

    /// Whether a stitch ticks now.
    static func ticks(phoneRunHoldsSession: Bool, duringPhoneRun: Bool = ticksDuringPhoneRun) -> Bool {
        duringPhoneRun || !phoneRunHoldsSession
    }
}

extension View {
    /// Plays `haptic` when `trigger` changes, if `condition` agrees with the change.
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T, when condition: @escaping (_ old: T, _ new: T) -> Bool = { _, _ in true }) -> some View {
        sensoryFeedback(trigger: trigger) { old, new in
            guard condition(old, new) else { return nil }
            #if DEBUG
            HapticLog.record(haptic)
            #endif
            return haptic.feedback
        }
    }

    /// A stitch's tick when `trigger` changes, if `condition` agrees with the change and `Haptic.ticks` allows it with the run as
    /// it is now.
    func stitchTickHaptic<T: Equatable>(trigger: T, when condition: @escaping (_ old: T, _ new: T) -> Bool = { _, _ in true }) -> some View {
        modifier(StitchTickHaptic(trigger: trigger, condition: condition))
    }
}

private struct StitchTickHaptic<T: Equatable>: ViewModifier {
    @Environment(ListeningCoordinator.self) private var run: ListeningCoordinator?
    let trigger: T
    let condition: (_ old: T, _ new: T) -> Bool

    func body(content: Content) -> some View {
        content.haptic(.stitchTick, trigger: trigger) { old, new in
            condition(old, new) && Haptic.ticks(phoneRunHoldsSession: run?.phoneRunHoldsSession ?? false)
        }
    }
}

/// How a control answers a press (issue #150, audit R2): a quick spring, or under Reduce Motion a dim and no movement.
enum PressFeel {
    /// A button sinks a little.
    static let sinks: CGFloat = 0.97
    /// A patch rises off the felt.
    static let rises: CGFloat = 1.04

    static func appearance(isPressed: Bool, scale: CGFloat, reduceMotion: Bool) -> (scale: CGFloat, opacity: Double) {
        guard isPressed else { return (1, 1) }
        return reduceMotion ? (1, 0.6) : (scale, 1)
    }
}

extension View {
    /// The press itself, for a `ButtonStyle` to apply to what it draws: `journalPrimary`, `journalOutlined`, `journalPress` and
    /// `patchLift` all do. Scaling leaves the hit area where it was.
    func pressResponse(isPressed: Bool, scale: CGFloat = PressFeel.sinks) -> some View {
        modifier(PressResponse(isPressed: isPressed, scale: scale))
    }
}

private struct PressResponse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let isPressed: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        let reduceMotion = PatchMotion.reduces(system: systemReduceMotion)
        let shown = PressFeel.appearance(isPressed: isPressed, scale: scale, reduceMotion: reduceMotion)
        content
            .scaleEffect(shown.scale)
            .opacity(shown.opacity)
            .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.18, dampingFraction: 0.6), value: isPressed)
    }
}

/// A control with no look of its own that still answers a press: a row, a pill or a text button.
struct PressButtonStyle: ButtonStyle {
    var scale = PressFeel.sinks

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressResponse(isPressed: configuration.isPressed, scale: scale)
    }
}

extension ButtonStyle where Self == PressButtonStyle {
    /// No look of its own; sinks when pressed.
    static var journalPress: PressButtonStyle { PressButtonStyle() }
    /// No look of its own; a patch, rising when pressed.
    static var patchLift: PressButtonStyle { PressButtonStyle(scale: PressFeel.rises) }
}

#if DEBUG
/// `-hapticLog YES` lists what was played, for the UI tests: a simulator has no Taptic Engine, and this at least proves the right
/// moments ask for the right haptics. What they feel like is for a phone.
@MainActor @Observable
final class HapticLog {
    static let shared = HapticLog()
    private(set) var played: [Haptic] = []

    nonisolated static func record(_ haptic: Haptic) {
        guard UserDefaults.standard.bool(forKey: "hapticLog") else { return }
        // A haptic is decided during a view update, which mustn't change what another view reads.
        Task { @MainActor in shared.played.append(haptic) }
    }
}

/// The list, where only a UI test will read it.
struct HapticLogProbe: View {
    var body: some View {
        if UserDefaults.standard.bool(forKey: "hapticLog") {
            Text(HapticLog.shared.played.map(\.rawValue).joined(separator: " "))
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("haptic-log")
        }
    }
}
#endif
