import ActivityKit
import SwiftUI
import WidgetKit

/// The run on the Lock Screen and in the Dynamic Island (issue #150).
struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunLockScreenContent(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RunIslandExpandedLeading(snapshot: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RunIslandStatus(snapshot: context.state)
                        .frame(maxHeight: .infinity)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunIslandExpandedBottom(snapshot: context.state)
                }
            } compactLeading: {
                RunIslandCompactLeading(snapshot: context.state)
            } compactTrailing: {
                RunIslandCompactTrailing(snapshot: context.state)
            } minimal: {
                RunIslandCompactLeading(snapshot: context.state)
            }
            .keylineTint(GlanceInk.tint(setID: context.state.setID, .dark, .standard))
        }
    }
}

/// The page colour under it, so the tints keep the contrast they were measured at.
private struct RunLockScreenContent: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let context: ActivityViewContext<RunActivityAttributes>

    var body: some View {
        RunLockScreenView(snapshot: context.state, isStale: context.isStale)
            .activityBackgroundTint(GlanceInk.page(scheme))
            .activitySystemActionForegroundColor(GlanceInk.ink(scheme, contrast))
    }
}
