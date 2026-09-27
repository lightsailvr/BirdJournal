import Foundation

/// Why a pack download stopped.
public enum PackDownloadError: Error, Equatable {
    case httpStatus(Int)
}

/// Streams a pack zip from its index URL to a file, reporting bytes received on the way (a pack is 40 to 170 MB, so
/// the phone shows progress). The caller verifies and installs the file; a failed or cancelled download leaves nothing.
public struct PackDownloader: Sendable {
    /// How often progress is reported, in bytes.
    static let reportEvery: Int64 = 1 << 18

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Downloads `descriptor.url` to `file` (replaced). `progress` gets the bytes received so far, at most every 256 KB.
    public func download(_ descriptor: PackDescriptor, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: descriptor.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PackDownloadError.httpStatus(http.statusCode)
        }
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        do {
            var buffer = Data()
            buffer.reserveCapacity(Int(Self.reportEvery))
            var received: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Int(Self.reportEvery) {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(received)
                }
            }
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            try handle.close()
            progress(received)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
