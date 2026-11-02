import Foundation

/// Scene art's life on a card (issue #68): a job starts, is painted, and lands or fails. Every change is to the one
/// sighting's art; nothing here ever writes another sighting, so a retry can't duplicate a card.
extension CardArt {
    /// What the card says about its scene art.
    public enum SceneStatus: Equatable, Sendable {
        /// No scene art and nothing under way.
        case none
        /// A job is queued or being painted: "Your encounter is saved. Artwork is on its way." Any earlier scene art
        /// stays on the card meanwhile.
        case pending
        /// The last job failed: Retry art or Keep current art.
        case failed
        /// Scene art is on file; the card shows it unless the birder chose pack art.
        case ready(showsPackArt: Bool)
    }

    public var sceneStatus: SceneStatus {
        if let job, job.kind == .scene {
            switch job.state {
            case .queued, .painting: return .pending
            case .failed: return .failed
            case .ready: break
            }
        }
        if let scene, scene.state == .ready, scene.path != nil { return .ready(showsPackArt: prefersPackArt) }
        return .none
    }

    /// The scene job under way (queued or painting), if any.
    public var pendingSceneJob: ArtJob? {
        guard let job, job.kind == .scene, job.state == .queued || job.state == .painting else { return nil }
        return job
    }

    /// A new scene job: the first after an add, or Try again and Retry art (each a new job, counted in `attempts`).
    /// The scene art already on file stays until the new one is ready.
    public mutating func startSceneJob(id: UUID) {
        job = ArtJob(id: id, kind: .scene, state: .queued, attempts: (job?.attempts ?? 0) + 1)
    }

    /// The server took the job up.
    public mutating func sceneJobPainting(id: UUID) {
        guard job?.id == id, job?.state == .queued else { return }
        job?.state = .painting
    }

    /// The painting arrived and is stored at `path`: it replaces the card's scene art and shows at once (a painting the
    /// birder asked for again is one they want to see). Returns the replaced painting's path, for the caller to delete;
    /// nil when there was none or the job is not this card's current one (a stale result changes nothing).
    @discardableResult
    public mutating func sceneJobReady(id: UUID, path: String) -> (applied: Bool, replaced: String?) {
        guard job?.id == id else { return (false, nil) }
        let replaced = scene?.path
        scene = ArtImage(path: path, state: .ready)
        prefersPackArt = false
        job = nil
        return (true, replaced == path ? nil : replaced)
    }

    /// The job failed (the painting machine's 7 days ran out, the filter, no faithful painting). The card keeps what it
    /// shows and offers Retry art.
    public mutating func sceneJobFailed(id: UUID) {
        guard job?.id == id else { return }
        job?.state = .failed
    }

    /// The server lost the job, or refused it (the auto-paint rule): nothing is under way any more.
    public mutating func sceneJobDropped(id: UUID) {
        guard job?.id == id else { return }
        job = nil
    }

    /// Keep current art: the failure is dismissed and the card stays as it is.
    public mutating func keepCurrentArt() {
        guard job?.state == .failed else { return }
        job = nil
    }
}
