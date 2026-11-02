import Album
import Foundation
import Network
import Observation
import OSLog
import Pack
import SwiftData

/// The finds waiting to reach the server (issue #62, spec v2 "Outbox"): puts and deletes, persisted on the phone and
/// sent while the birder is signed in and online, retried with backoff when the network or the server fails.
///
/// Only sightings added while signed in and sharing are published (`FindPolicy.publishesAutomatically`); the outbox
/// remembers them as `published`, per account, so a later Heard-to-Seen or a restored removal puts the find again, and
/// a removal deletes it. Each entry belongs to the account that published it: signing out stops publishing, and
/// signing in as another account never sends the first one's finds. One entry per sighting: the latest change wins
/// (a put then a delete before either was sent is a delete).
///
/// The payload is built when the entry is sent, from the sighting as it is then, through the find policy, so a put
/// queued offline carries the city the phone can name once it is back online.
@MainActor
@Observable
final class FindOutbox {
    enum Operation: String, Codable, Sendable {
        case put
        case delete
    }

    struct Entry: Codable, Equatable, Sendable {
        /// New for every change, so a send that finishes after a newer change doesn't clear it.
        var id = UUID()
        var owner: String
        var identifier: UUID
        var operation: Operation
        var attempts = 0
        var retryAfter: Date?
    }

    /// A sighting this account published as a find.
    struct Published: Codable, Hashable, Sendable {
        var owner: String
        var identifier: UUID
        /// The Legendary flag the find was published with: frozen at the add.
        var isLegendary: Bool
    }

    private struct Saved: Codable {
        var entries: [Entry]
        var published: [Published]
    }

    /// What is waiting, oldest first.
    private(set) var entries: [Entry] = []
    private(set) var published: [Published] = []

    static let maximumBackoff: TimeInterval = 300

    @ObservationIgnored private let account: AccountSession
    @ObservationIgnored private let client: CircleClient?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let sharing: () -> FindPolicy.Sharing
    @ObservationIgnored private let payload: (UUID, Bool) async -> FindPolicy.Find?
    @ObservationIgnored private let isOnline: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var flushAgain = false
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "finds")

    /// - Parameters:
    ///   - fileURL: where the outbox persists; nil keeps it in memory.
    ///   - payload: the find of a sighting by identifier, with its frozen Legendary flag; nil when the sighting is
    ///     gone, which drops its put.
    init(
        account: AccountSession, client: CircleClient?, fileURL: URL?, sharing: @escaping () -> FindPolicy.Sharing,
        payload: @escaping (UUID, Bool) async -> FindPolicy.Find?, isOnline: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) {
        self.account = account
        self.client = client
        self.fileURL = fileURL
        self.sharing = sharing
        self.payload = payload
        self.isOnline = isOnline
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            entries = saved.entries
            published = saved.published
        }
    }

    /// The account the phone is signed in as, when it is.
    private var signedInOwner: String? {
        account.isSignedIn ? account.identity.subject : nil
    }

    // What the journal tells it.

    /// A sighting was added. It is published when the birder is signed in and sharing, now or once online.
    func added(_ identifier: UUID, isLegendary: Bool) {
        guard client != nil, let owner = signedInOwner,
              FindPolicy.publishesAutomatically(sharing: sharing(), signedIn: true) else { return }
        published.append(Published(owner: owner, identifier: identifier, isLegendary: isLegendary))
        enqueue(.put, identifier, owner: owner)
    }

    /// A card was shared by hand (issue #66): the sighting is now on the server, so a later Heard-to-Seen puts it again
    /// and a removal deletes it, as for an automatic find, whatever the sharing setting.
    func sharedByHand(_ identifier: UUID, isLegendary: Bool) {
        guard let owner = signedInOwner, !published.contains(where: { $0.owner == owner && $0.identifier == identifier }) else { return }
        published.append(Published(owner: owner, identifier: identifier, isLegendary: isLegendary))
        save()
    }

    /// Whether an automatic put of the sighting is still waiting to go (offline, or backing off).
    func isWaitingToPublish(_ identifier: UUID) -> Bool {
        entries.contains { $0.identifier == identifier && $0.operation == .put && $0.owner == signedInOwner }
    }

    /// The Legendary flag a sighting was published with, frozen at the add; nil when it never was.
    func publishedLegendary(_ identifier: UUID) -> Bool? {
        published.last { $0.identifier == identifier && $0.owner == signedInOwner }?.isLegendary
    }

    /// A published sighting changed (Heard or Seen): its find is put again. Others change nothing.
    func changed(_ identifier: UUID) {
        guard let owner = owner(of: identifier) else { return }
        enqueue(.put, identifier, owner: owner)
    }

    /// A sighting was removed: its find, if it has one, is deleted.
    func removed(_ identifier: UUID) {
        guard let owner = owner(of: identifier) else { return }
        enqueue(.delete, identifier, owner: owner)
    }

    /// A removal was undone: the find comes back.
    func restored(_ identifier: UUID) {
        changed(identifier)
    }

    // Sending.

    /// Sends what is due for the signed-in account; does nothing signed out or offline. Called after every change,
    /// on sign-in, when the network comes back and when the app becomes active, and by its own retry.
    func flush() async {
        if let running {
            // One drain at a time; a caller during one waits for it, and it runs once more for the new change.
            flushAgain = true
            await running.value
            return
        }
        let drain = Task {
            repeat {
                flushAgain = false
                await sendDue()
            } while flushAgain
            // Cleared in the drain itself, so no caller can wait on a drain that has already checked for more.
            running = nil
            scheduleRetry()
        }
        running = drain
        await drain.value
    }

    private func sendDue() async {
        guard let client, let owner = signedInOwner, isOnline() else { return }
        for entry in entries where entry.owner == owner && (entry.retryAfter ?? .distantPast) <= now() {
            guard signedInOwner == owner else { return }
            // Replaced by a newer change while an earlier send was out: the newer one goes in the next pass.
            guard entries.contains(where: { $0.id == entry.id }) else { continue }
            do {
                switch entry.operation {
                case .put:
                    let legendary = published.first { $0.owner == owner && $0.identifier == entry.identifier }?.isLegendary ?? false
                    guard let find = await payload(entry.identifier, legendary) else {
                        // The sighting is gone (its delete is queued on its own) or no longer makes a find.
                        finish(entry)
                        continue
                    }
                    try await account.withAccessToken(doing: "share your find") {
                        try await client.putFind(find, sightingID: entry.identifier, accessToken: $0)
                    }
                case .delete:
                    // The published record stays: an Undo after the delete went puts the find back.
                    try await account.withAccessToken(doing: "remove your find") {
                        try await client.deleteFind(sightingID: entry.identifier, accessToken: $0)
                    }
                }
                finish(entry)
            } catch AuthError.sessionExpired {
                return
            } catch {
                if Self.isPermanent(error) {
                    log.error("find \(entry.operation.rawValue) refused, dropped: \(String(describing: error))")
                    finish(entry)
                } else {
                    log.info("find \(entry.operation.rawValue) failed, will retry: \(String(describing: error))")
                    backOff(entry)
                    if !isOnline() { return }
                }
            }
        }
    }

    /// A refusal that a retry can't fix: the server turned the find down. Network errors, 429 and 5xx retry.
    static func isPermanent(_ error: Error) -> Bool {
        switch error {
        case CircleError.rejected, CircleError.notFound, CircleError.creatorOnly: true
        case CircleError.server(let status): (400..<500).contains(status) && status != 408 && status != 429
        default: false
        }
    }

    /// The wait before the next attempt: 2, 4, 8 … seconds, at most five minutes.
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        min(maximumBackoff, pow(2, Double(min(attempts, 16))))
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = nil
        guard let owner = signedInOwner,
              let next = entries.filter({ $0.owner == owner }).compactMap(\.retryAfter).min() else { return }
        let delay = max(0, next.timeIntervalSince(now()))
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    // Bookkeeping.

    private func owner(of identifier: UUID) -> String? {
        published.last { $0.identifier == identifier }?.owner
    }

    private func enqueue(_ operation: Operation, _ identifier: UUID, owner: String) {
        entries.removeAll { $0.owner == owner && $0.identifier == identifier }
        entries.append(Entry(owner: owner, identifier: identifier, operation: operation))
        save()
        // Offline or signed out as another account, it waits for the network or the sign-in to send it.
        if signedInOwner == owner, isOnline() { Task { await flush() } }
    }

    private func finish(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func backOff(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].attempts += 1
        entries[index].retryAfter = now().addingTimeInterval(Self.backoff(afterAttempts: entries[index].attempts))
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Saved(entries: entries, published: published)).write(to: fileURL, options: .atomic)
        } catch {
            log.error("couldn't save the find outbox: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension FindOutbox {
    /// The setting's key: "Share my finds automatically", on by default.
    static let sharingKey = "shareFindsAutomatically"

    static var sharingSetting: FindPolicy.Sharing {
        UserDefaults.standard.object(forKey: sharingKey) as? Bool == false ? .private : .automatic
    }

    /// The app's outbox, persisted in Application Support, over the circle server's client (none when the build has
    /// no server or accounts are off), sending while the network monitor says the phone is online. The debug
    /// in-memory album keeps the outbox in memory too.
    static func forApp(account: AccountSession, client: CircleClient?, album: ModelContainer, packs: PackLibrary, places: PlaceNames) -> FindOutbox {
        var fileURL = URL.applicationSupportDirectory.appending(path: "FindOutbox.json")
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "inMemoryAlbum") { fileURL = URL.temporaryDirectory.appending(path: "FindOutbox-\(UUID().uuidString).json") }
        #endif
        let network = NetworkStatus()
        let outbox = FindOutbox(
            account: account, client: AccountSession.isEnabledInThisBuild ? client : nil, fileURL: fileURL,
            sharing: { sharingSetting },
            payload: { identifier, legendary in
                await find(of: identifier, isLegendary: legendary, album: album, packs: packs, places: places)
            },
            isOnline: { network.isOnline }
        )
        network.onOnline = { [weak outbox] in Task { await outbox?.flush() } }
        return outbox
    }

    /// The find of the sighting with `identifier` in the album, through the find policy: its species and card facts
    /// from the packs, the city the phone names for its place, and its pack art's thumbnail.
    static func find(of identifier: UUID, isLegendary: Bool, album: ModelContainer, packs: PackLibrary, places: PlaceNames) async -> FindPolicy.Find? {
        var descriptor = FetchDescriptor<Sighting>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        guard let sighting = try? album.mainContext.fetch(descriptor).first else { return nil }
        if packs.species(scientificName: sighting.scientificName)?.species.isThreatened == false, let location = sighting.location {
            await places.resolve(location)
        }
        let input = input(of: sighting, isLegendary: isLegendary, packs: packs, places: places)
        return FindPolicy.find(for: input, sharing: .automatic)
    }
}

extension FindOutbox {
    /// What the find policy reads about a sighting: its species and card facts from the packs, the city the phone has
    /// named for its place (only for a species known not to be threatened), and its pack art's thumbnail. The note and
    /// the caption ride along for a card shared by hand; an automatic find leaves them out.
    @MainActor
    static func input(of sighting: Sighting, isLegendary: Bool, packs: PackLibrary, places: PlaceNames) -> FindPolicy.Input {
        let isThreatened = packs.species(scientificName: sighting.scientificName)?.species.isThreatened
        let placeName = isThreatened == false ? sighting.location.flatMap(places.name(for:)) : nil
        let setID = CardSet.placement(speciesID: sighting.speciesID, at: sighting.location, in: packs.cardSets).setID
        let art = packs.packArt(scientificName: sighting.scientificName, setID: setID)
        return FindPolicy.Input(
            identifier: sighting.identifier, speciesID: sighting.speciesID, commonName: packs.commonName(for: sighting),
            method: sighting.method, confirmedAt: sighting.confirmedAt, rarity: sighting.rarity?.label, isLegendary: isLegendary,
            isThreatened: isThreatened, placeName: placeName, packArt: art.map { ($0.pack.info.id, $0.art.file) },
            note: sighting.note, caption: sighting.caption?.text
        )
    }
}

/// Whether the phone has a usable network path, from `NWPathMonitor`, and a call when it comes back.
nonisolated final class NetworkStatus: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    var onOnline: (@MainActor () -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isOnline = path.status == .satisfied
            let cameBack = lock.withLock {
                defer { online = isOnline }
                return isOnline && !online
            }
            if cameBack { Task { @MainActor in self.onOnline?() } }
        }
        monitor.start(queue: DispatchQueue(label: "com.matthewcelia.mybirdjournal.network"))
    }

    var isOnline: Bool { lock.withLock { online } }
}
