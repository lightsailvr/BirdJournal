import SwiftUI
import UIKit
import WidgetKit

/// What one drawing of the widget needs. The picture travels as its bytes: an entry has to be sendable.
struct LatestPatchEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let patchPNG: Data?
}

/// One entry: what the app last wrote. The app reloads the timeline whenever it writes, so the widget never polls.
struct LatestPatchProvider: TimelineProvider {
    private func current() -> LatestPatchEntry {
        let store = WidgetStore.shared
        return LatestPatchEntry(date: .now, snapshot: store?.snapshot() ?? WidgetSnapshot(), patchPNG: store?.patchImage())
    }

    func placeholder(in context: Context) -> LatestPatchEntry {
        LatestPatchEntry(date: .now, snapshot: WidgetSnapshot(), patchPNG: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LatestPatchEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LatestPatchEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }
}

struct LatestPatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: LatestPatchProvider()) { entry in
            LatestPatchEntryView(entry: entry)
        }
        .configurationDisplayName("Latest patch")
        .description("Your newest patch, and how far along its set is.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct LatestPatchEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LatestPatchEntry

    var body: some View {
        LatestPatchWidgetView(snapshot: entry.snapshot, patchImage: entry.patchPNG.flatMap(UIImage.init(data:)), family: family)
    }
}
