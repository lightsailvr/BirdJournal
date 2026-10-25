import Foundation
import Observation
import OSLog

/// What the glasses' camera and stream did this app session, newest last: the restarts after a clip, the stream
/// checks, the photos. Shown on the glasses diagnostics screen so a field test can be read on the phone, sent to the
/// unified log too (category "glasses-audio"), and appended to a file per day in the app container
/// (`Library/Application Support/Logs/glasses-<date>.log`), which outlives the app and can be pulled with
/// `devicectl device copy from` after a walk (#46).
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
    @ObservationIgnored private let file = LogFile()
    private static let stamp = formatter("HH:mm:ss.SSS")
    private static let day = formatter("yyyy-MM-dd")

    /// Local time, so the file reads against the wearer's own notes of the walk.
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

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
        let entry = Entry(id: nextID, at: .now, text: text, isError: isError)
        entries.append(entry)
        file.append("\(Self.stamp.string(from: entry.at)) \(isError ? "E" : "I") \(text)\n", day: Self.day.string(from: entry.at))
        nextID += 1
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}

/// The day's log file, written in order off the main actor. A write that fails is dropped: the log is for diagnosis
/// and must never get in the way of a run.
private nonisolated final class LogFile: Sendable {
    private let queue = DispatchQueue(label: "com.matthewcelia.mybirdjournal.glasses-log")

    /// Appends `line` to the file for `day`.
    func append(_ line: String, day: String) {
        queue.async {
            guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "Logs", directoryHint: .isDirectory) else { return }
            let url = directory.appending(path: "glasses-\(day).log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {}
        }
    }
}
