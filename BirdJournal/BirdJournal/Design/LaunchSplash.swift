import SwiftUI
import UIKit

/// The moment after the launch screen on the first launch only (issue #150, audit F15): later launches go straight to Listen,
/// for someone reaching for the phone because a bird is calling. It starts as the launch screen (`UILaunchScreen` in the Info.plist, the paper
/// colour with the `PerchedFinch` image, the patch and its shadow at 240 × 240 pt in the middle of the screen), sets the app's
/// name in the serif under the bird, then fades away over the Listen tab, which is already built underneath. It takes
/// no touches and hides from VoiceOver, so nothing waits on it.
///
/// The launch screen follows the system appearance, not the one picked in Settings, so the splash starts in the
/// system's and crossfades into the app's with its fade. Both draw the same picture, so nothing moves between them.
struct LaunchSplash: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var appScheme
    @State private var showsTitle = false
    private let systemScheme = Self.systemColorScheme

    static let birdSize = CGSize(width: 240, height: 240)
    /// Remembers that it played.
    static let shownKey = "launchSplashShown"

    static func isDue(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: shownKey)
    }

    var body: some View {
        ZStack {
            Color.paper
            art
                .frame(width: Self.birdSize.width, height: Self.birdSize.height)
                .overlay(alignment: .bottom) {
                    Text("Featherguild")
                        .font(JournalFont.largeTitle)
                        .foregroundStyle(Color.ink)
                        .fixedSize()
                        .opacity(showsTitle ? 1 : 0)
                        .offset(y: showsTitle || reduceMotion ? 64 : 76)
                }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, systemScheme ?? appScheme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIdentifier("launch-splash")
        .task {
            // From the start: a launch killed part way through has still shown it.
            UserDefaults.standard.set(true, forKey: Self.shownKey)
            withAnimation(.easeOut(duration: 0.6)) { showsTitle = true }
            try? await Task.sleep(for: holds)
            onFinished()
        }
    }

    /// The mascot's patch: the picture the launch screen shows too, so nothing moves between them.
    private var art: some View {
        Image("PerchedFinch").resizable()
    }

    private var holds: Duration {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "launchSplashSeconds")
        if seconds > 0 { return .seconds(seconds) }
        #endif
        return .milliseconds(1100)
    }

    /// The appearance the launch screen was drawn in: the screen's, which the window's override does not change.
    private static var systemColorScheme: ColorScheme? {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        guard let style = scene?.screen.traitCollection.userInterfaceStyle else { return nil }
        return style == .dark ? .dark : .light
    }
}
