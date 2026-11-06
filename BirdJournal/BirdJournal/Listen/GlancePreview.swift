#if DEBUG
import SwiftUI
import UIKit
import WidgetKit

/// `-autoScreen glance` (issue #150): the Live Activity's and the widget's own views, drawn in the app at a phone's sizes, from
/// the files the app really wrote to the App Group. For the screenshots and for looking at them in both appearances; the
/// surfaces themselves are checked by hand on a phone.
struct GlancePreview: View {
    @Environment(\.colorScheme) private var scheme

    private static let run = RunSnapshot(phase: .listening, startedAt: .now.addingTimeInterval(-2_532), birdsHeard: 3, newPatchesWaiting: 1, setID: "us-ca-la")
    private static let empty = WidgetSnapshot(progress: .init(setID: "us-ca-la", setName: "Los Angeles", sewn: 0, total: 160))

    /// `-glancePage widgets`: the widgets alone, so they fit one screenshot.
    private static var showsWidgets: Bool { UserDefaults.standard.string(forKey: "glancePage") == "widgets" }

    @State private var snapshot: WidgetSnapshot?
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if Self.showsWidgets {
                    if let snapshot {
                        HStack(spacing: 14) {
                            widget(snapshot, image, .systemSmall, width: 170)
                            widget(Self.empty, nil, .systemSmall, width: 170)
                        }
                        widget(snapshot, image, .systemMedium, width: 354)
                        widget(Self.empty, nil, .systemMedium, width: 354)
                    } else {
                        Text("No widget files were written.")
                    }
                } else {
                    RunLockScreenView(snapshot: Self.run)
                        .background(GlanceInk.page(scheme), in: RoundedRectangle(cornerRadius: 22))
                    RunLockScreenView(snapshot: RunSnapshot(phase: .paused, startedAt: .now.addingTimeInterval(-300), birdsHeard: 1, newPatchesWaiting: 0, pausedTitle: "Paused: glasses off"))
                        .background(GlanceInk.page(scheme), in: RoundedRectangle(cornerRadius: 22))
                    island
                }
            }
            .padding(16)
            .accessibilityIdentifier("glance")
        }
        .background(Color.black.opacity(scheme == .dark ? 1 : 0.2))
        .task {
            // The app writes the files a moment after launch.
            while !Task.isCancelled {
                snapshot = WidgetStore.shared?.snapshot()
                image = WidgetStore.shared?.patchImage().flatMap(UIImage.init(data:))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The Island is always dark, whatever the phone's appearance.
    private var island: some View {
        VStack(spacing: 10) {
            HStack {
                RunIslandCompactLeading(snapshot: Self.run)
                Spacer(minLength: 120)
                RunIslandCompactTrailing(snapshot: Self.run)
            }
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(.black, in: Capsule())
            HStack {
                RunIslandCompactLeading(snapshot: RunSnapshot(phase: .listening, startedAt: .now.addingTimeInterval(-61), birdsHeard: 2, newPatchesWaiting: 0, setID: "us-ca-sd"))
                Spacer(minLength: 120)
                RunIslandCompactTrailing(snapshot: RunSnapshot(phase: .listening, startedAt: .now.addingTimeInterval(-61), birdsHeard: 2, newPatchesWaiting: 0, setID: "us-ca-sd"))
            }
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(.black, in: Capsule())
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    RunIslandExpandedLeading(snapshot: Self.run)
                    Spacer()
                    RunActivityCounts(snapshot: Self.run, alignment: .trailing)
                }
                RunActivityStop(snapshot: Self.run)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(18)
            .background(.black, in: RoundedRectangle(cornerRadius: 36))
        }
        .environment(\.colorScheme, .dark)
    }

    private func widget(_ snapshot: WidgetSnapshot, _ image: UIImage?, _ family: WidgetFamily, width: CGFloat) -> some View {
        LatestPatchWidgetView(snapshot: snapshot, patchImage: image, family: family)
            .padding(16)
            .frame(width: width, height: 170)
            .background { GlanceBoard() }
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}
#endif
