import Foundation
import Observation
import OSLog

/// The packs the app reads (issue #13): the pack bundled in the binary first, then every pack downloaded from the
/// index, looked up as one. Downloads run one task per pack; their state is published for the packs screen.
@MainActor
@Observable
public final class PackLibrary {
    /// Where a pack from the index stands on this phone.
    public enum Status: Equatable, Sendable {
        case bundled
        case notInstalled
        case installed(version: Int)
        case updateAvailable(installed: Int, available: Int)
        /// Bytes received so far.
        case downloading(received: Int64)
        case installing
        case failed(String)
    }

    private static let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "packs")

    /// The pack compiled into the app, nil when the bundle lacks it (every species then shows by name alone).
    public let bundled: SpeciesPack?
    public let storage: PackStorage
    public let indexURL: URL
    public private(set) var installed: [InstalledPack]
    public private(set) var index: PackIndex?
    /// Why the last index fetch failed, nil after a good one.
    public private(set) var indexError: String?
    public private(set) var isRefreshingIndex = false
    /// The download or failure state per pack id; absent when nothing is in flight.
    private var transfers: [String: Status] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let downloader: PackDownloader
    @ObservationIgnored private let session: URLSession

    public init(bundled: SpeciesPack?, storage: PackStorage, indexURL: URL = PackIndex.defaultURL, session: URLSession = .shared) {
        self.bundled = bundled
        self.storage = storage
        self.indexURL = indexURL
        self.session = session
        self.downloader = PackDownloader(session: session)
        self.installed = storage.installed()
    }

    // MARK: - Reading

    /// Every readable pack: the bundled one, then the downloads.
    public var packs: [SpeciesPack] {
        (bundled.map { [$0] } ?? []) + installed.map(\.pack)
    }

    public func pack(id: String) -> SpeciesPack? {
        packs.first { $0.info.id == id }
    }

    /// The first pack (bundled first) that has this species, with its entry.
    public func species(scientificName: String) -> (pack: SpeciesPack, species: PackSpecies)? {
        for pack in packs {
            if let species = pack.species(scientificName: scientificName) { return (pack, species) }
        }
        return nil
    }

    /// The first pack that has this photo (an iNaturalist photo id; two packs sharing a species share its photos).
    public func photo(id: String) -> (pack: SpeciesPack, photo: PackPhoto)? {
        for pack in packs {
            if let photo = pack.photo(id: id) { return (pack, photo) }
        }
        return nil
    }

    // MARK: - The index

    /// The index's packs that are neither bundled nor installed: what the packs screen offers to download. A build
    /// whose bundle lacks its pack is offered it like any other.
    public var available: [PackDescriptor] {
        (index?.packs ?? []).filter { !isBundled($0.id) && installedPack(id: $0.id) == nil }
    }

    public func status(of descriptor: PackDescriptor) -> Status {
        if let transfer = transfers[descriptor.id] { return transfer }
        if isBundled(descriptor.id) { return .bundled }
        guard let installed = installedPack(id: descriptor.id) else { return .notInstalled }
        if descriptor.version > installed.descriptor.version {
            return .updateAvailable(installed: installed.descriptor.version, available: descriptor.version)
        }
        return .installed(version: installed.descriptor.version)
    }

    /// Fetches the index again; a failure keeps the last good index and records why.
    public func refreshIndex() async {
        isRefreshingIndex = true
        defer { isRefreshingIndex = false }
        do {
            index = try await PackIndex.fetch(from: indexURL, session: session)
            indexError = nil
        } catch {
            indexError = error.localizedDescription
        }
    }

    // MARK: - Downloads

    /// Starts downloading `descriptor` in its own task, unless it already is.
    public func startDownload(_ descriptor: PackDescriptor) {
        guard tasks[descriptor.id] == nil else { return }
        tasks[descriptor.id] = Task { [weak self] in
            await self?.download(descriptor)
        }
    }

    public func cancelDownload(id: String) {
        tasks[id]?.cancel()
    }

    /// Downloads, verifies and installs `descriptor`, publishing progress as `status(of:)`; on failure the status
    /// says why and nothing is installed. Returns when the pack is in `packs` or the download has failed.
    public func download(_ descriptor: PackDescriptor) async {
        let id = descriptor.id
        setTransfer(id, .downloading(received: 0))
        let zip = URL.temporaryDirectory.appending(path: "\(id)-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: zip)
            tasks[id] = nil
        }
        do {
            let downloader = downloader
            try await Self.offMain {
                try await downloader.download(descriptor, to: zip) { received in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.transfers[id] else { return }
                        self.setTransfer(id, .downloading(received: received))
                    }
                }
            }
            try Task.checkCancellation()
            setTransfer(id, .installing)
            let storage = storage
            let installedPack = try await Self.offMain { try storage.install(zip: zip, as: descriptor) }
            try Task.checkCancellation()
            installed = installed.filter { $0.id != id } + [installedPack]
            installed.sort { $0.descriptor.name < $1.descriptor.name }
            setTransfer(id, nil)
            Self.log.info("installed pack \(id) v\(descriptor.version)")
        } catch is CancellationError {
            Self.log.info("download of \(id) cancelled")
            setTransfer(id, nil)
        } catch let error as URLError where error.code == .cancelled {
            Self.log.info("download of \(id) cancelled by the session")
            setTransfer(id, nil)
        } catch {
            Self.log.error("download of \(id) failed: \(String(describing: error))")
            setTransfer(id, .failed(Self.message(for: error)))
        }
    }

    /// Forgets a failed download so the pack is offered again.
    public func dismissFailure(id: String) {
        if case .failed = transfers[id] { setTransfer(id, nil) }
    }

    /// Deletes a downloaded pack's files; its species are gone from `packs` at once, and a download of the same
    /// pack still in flight is cancelled.
    public func remove(id: String) throws {
        tasks[id]?.cancel()
        try storage.remove(id: id)
        installed.removeAll { $0.id == id }
        setTransfer(id, nil)
    }

    private func isBundled(_ id: String) -> Bool {
        bundled?.info.id == id
    }

    private func installedPack(id: String) -> InstalledPack? {
        installed.first { $0.id == id }
    }

    private func setTransfer(_ id: String, _ status: Status?) {
        transfers[id] = status
    }

    /// Runs `work` in its own task off the main actor (a 165 MB stream and its hashing and unpacking do not belong
    /// there), forwarding cancellation to it: a detached task is not a child, so without this Cancel would let the
    /// whole download finish before the status cleared.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case PackInstallError.checksumMismatch: "The download's checksum did not match the index."
        case PackDownloadError.httpStatus(let code): "The server answered \(code)."
        case let error as ZipError: "The download is not a pack zip (\(error))."
        case let error as PackError: "The download is not a readable pack (\(error))."
        default: error.localizedDescription
        }
    }
}
