import SwiftUI
import UIKit

/// The moment after the launch screen: it starts as the launch screen (`UILaunchScreen` in the Info.plist, the paper
/// colour with the `LaunchBird` image, the perched bird at 240 × 144 pt in the middle of the screen), sets the app's
/// name in the serif under the bird, then fades away over the Listen tab, which is already built underneath. It takes
/// no touches and hides from VoiceOver, so nothing waits on it.
///
/// The launch screen follows the system appearance, not the one picked in Settings, so the splash starts in the
/// system's and crossfades into the app's with its fade. `LaunchBird` is rendered from `PerchedBirdDrawing` at that
/// size; re-render it if the drawing changes.
struct LaunchSplash: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var appScheme
    @State private var showsTitle = false
    private let systemScheme = Self.systemColorScheme

    static let birdSize = CGSize(width: 240, height: 144)

    var body: some View {
        ZStack {
            Color.paper
            PerchedBirdDrawing()
                .frame(width: Self.birdSize.width, height: Self.birdSize.height)
                .overlay(alignment: .bottom) {
                    Text("My Bird Journal")
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
        .task {
            withAnimation(.easeOut(duration: 0.6)) { showsTitle = true }
            try? await Task.sleep(for: .milliseconds(1100))
            onFinished()
        }
    }

    /// The appearance the launch screen was drawn in: the screen's, which the window's override does not change.
    private static var systemColorScheme: ColorScheme? {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        guard let style = scene?.screen.traitCollection.userInterfaceStyle else { return nil }
        return style == .dark ? .dark : .light
    }
}
