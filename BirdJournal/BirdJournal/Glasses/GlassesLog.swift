import Foundation
import Observation
import OSLog

/// What the glasses' camera and stream did this app session, newest last: the restarts after a clip, the viewfinder's
/// stream, the photos. Shown on the glasses diagnostics screen so a field test can be read on the phone, and sent to
/// the unified log too (category "glasses-audio").
@MainActor
@Observable
final class GlassesLog {
    static let shared = GlassesLog()

    struct Entry: Identifiable, Equatable {
        let id: Int
        let at: Date
        let text: String
        let isError: Bool
    }

    /// The most entries kept; older ones drop off.
    static let limit = 200

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var nextID = 0
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "glasses-audio")

    func note(_ text: String) {
        Self.logger.info("\(text, privacy: .public)")
        append(text, isError: false)
    }

    func error(_ text: String) {
        Self.logger.error("\(text, privacy: .public)")
        append(text, isError: true)
    }

    func clear() {
        entries = []
    }

    private func append(_ text: String, isError: Bool) {
        entries.append(Entry(id: nextID, at: .now, text: text, isError: isError))
        nextID += 1
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
