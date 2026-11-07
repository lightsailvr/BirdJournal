import SwiftUI
import WidgetKit

/// The widget extension (issue #150): the run's Live Activity and the latest-patch widget. It reads what the app writes and
/// draws what's in `Glance/`, and it has none of the app's packages.
@main
struct BirdJournalWidgets: WidgetBundle {
    var body: some Widget {
        LatestPatchWidget()
        RunLiveActivity()
    }
}
