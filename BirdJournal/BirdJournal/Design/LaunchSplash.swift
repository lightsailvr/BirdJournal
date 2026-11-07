import SwiftUI

/// The mascot's launch-screen dimensions, also checked against the bundled asset by `MascotTests`.
enum LaunchSplash {
    static let birdSize = CGSize(width: 240, height: 240)
}

/// Matches the static launch screen immediately; only slow launches gain the accessible status and quiet spinner.
/// The gate stays up for real work, including repeat launches, and never imposes a minimum display time.
struct LaunchLoadingView: View {
    var error: String?
    var continueLoading: (() -> Void)? = nil
    var retry: () -> Void
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            Image("PerchedFinch")
                .resizable()
                .frame(width: LaunchSplash.birdSize.width, height: LaunchSplash.birdSize.height)
                .accessibilityHidden(true)
                .overlay(alignment: .bottom) {
                    if showsProgress || error != nil {
                        VStack(spacing: 12) {
                            if let error {
                                Text(error).font(.subheadline).multilineTextAlignment(.center)
                                Button("Try again", action: retry)
                            } else {
                                ProgressView()
                                Text("Opening your journal…").font(.subheadline)
                                #if DEBUG
                                if let continueLoading {
                                    Button("Continue", action: continueLoading).accessibilityIdentifier("launch-continue")
                                }
                                #endif
                            }
                        }
                        .foregroundStyle(Color.ink)
                        .offset(y: 88)
                    }
                }
        }
        .accessibilityIdentifier("launch-splash")
        .task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            showsProgress = true
        }
    }
}
