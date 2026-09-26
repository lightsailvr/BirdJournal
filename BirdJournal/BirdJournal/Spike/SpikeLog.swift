import Foundation

/// Append-only text log for one spike run: one timestamped `event key=value …` line per record, written to
/// Documents/Spike so it survives the app and can be shared from the phone.
final class SpikeLog {
    let url: URL
    private let handle: FileHandle
    private let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static var directory: URL {
        URL.documentsDirectory.appending(path: "Spike", directoryHint: .isDirectory)
    }

    init(startedAt date: Date) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        url = Self.directory.appending(path: "spike-\(formatter.string(from: date)).log")
        FileManager.default.createFile(atPath: url.path(), contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    /// Writes `event` followed by its fields in order, and returns the line as written.
    @discardableResult
    func write(_ event: String, _ fields: [(String, String)] = []) -> String {
        let body = ([event] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: " ")
        let line = "\(Date.now.formatted(timestampFormat)) \(body)"
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        return line
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }
}
