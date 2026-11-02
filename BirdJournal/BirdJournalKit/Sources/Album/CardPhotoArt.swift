import Foundation

/// Photo art's life on a card (issue #69): the birder's own photo of the bird, painted, then compared with the original
/// and approved, kept as it was ("Keep original") or painted again. The original photo is never touched here: a job
/// names it as its `source`, and every painting is a file of its own. Every change is to the one sighting's art, so a
/// retry can't duplicate a card.
extension CardArt {
    /// What the card says about its photo art.
    public enum PhotoStatus: Equatable, Sendable {
        /// No photo art and nothing under way.
        case none
        /// The photo is being painted. Any approved photo art stays on the card meanwhile.
        case pending
        /// The last painting failed: Retry art or Keep current art.
        case failed
        /// A painting waits for the birder beside its original: Approve, Keep original or Try again.
        case preview(path: String, source: String?)
        /// Approved photo art is on the card, labelled "AI-embellished from your photo".
        case approved
    }

    public var photoStatus: PhotoStatus {
        if let photoJob {
            switch photoJob.state {
            case .queued, .painting: return .pending
            case .failed: return .failed
            case .ready: break
            }
        }
        if let photoPreview, let path = photoPreview.path { return .preview(path: path, source: photoPreview.source) }
        if let photo, photo.state == .ready, photo.path != nil { return .approved }
        return .none
    }

    /// The photo job under way (queued or painting), if any.
    public var pendingPhotoJob: ArtJob? {
        guard let photoJob, photoJob.state == .queued || photoJob.state == .painting else { return nil }
        return photoJob
    }

    /// A new photo-art job painting `source` (the glasses photo or an attached original): the first, or Try again and
    /// Retry art (each a new job, counted in `attempts`). Approved art and any waiting painting stay until it's done.
    public mutating func startPhotoJob(id: UUID, source: String) {
        photoJob = ArtJob(id: id, kind: .photo, state: .queued, attempts: (photoJob?.attempts ?? 0) + 1, source: source)
    }

    public mutating func photoJobPainting(id: UUID) {
        guard photoJob?.id == id, photoJob?.state == .queued else { return }
        photoJob?.state = .painting
    }

    /// The painting arrived and is stored at `path`: it waits for the birder beside its original. Returns whether it
    /// applied and the earlier waiting painting it replaced, for the caller to delete.
    @discardableResult
    public mutating func photoJobReady(id: UUID, path: String) -> (applied: Bool, replaced: String?) {
        guard photoJob?.id == id else { return (false, nil) }
        let replaced = photoPreview?.path
        photoPreview = ArtImage(path: path, state: .preview, source: photoJob?.source)
        photoJob?.state = .ready
        return (true, replaced == path ? nil : replaced)
    }

    public mutating func photoJobFailed(id: UUID) {
        guard photoJob?.id == id, photoJob?.state != .ready else { return }
        photoJob?.state = .failed
    }

    /// The server refused the job (today's allowance spent) or lost it: nothing is under way any more.
    public mutating func photoJobDropped(id: UUID) {
        guard photoJob?.id == id else { return }
        photoJob = nil
    }

    /// Approve: the waiting painting becomes the card's art. Returns the earlier approved painting it replaced, for the
    /// caller to delete. The original stays where it is.
    @discardableResult
    public mutating func approvePhotoArt() -> String? {
        guard let preview = photoPreview, preview.path != nil else { return nil }
        let replaced = photo?.path
        photo = ArtImage(path: preview.path, state: .ready, source: preview.source)
        photoPreview = nil
        return replaced == preview.path ? nil : replaced
    }

    /// Keep original: the waiting painting is let go and the card stays as it was. Returns its path, for the caller to
    /// delete; the original photo is kept as the card's evidence.
    @discardableResult
    public mutating func keepOriginalPhoto() -> String? {
        let discarded = photoPreview?.path
        photoPreview = nil
        return discarded
    }

    /// Keep current art after a failed photo painting: the failure is dismissed.
    public mutating func keepCurrentPhotoArt() {
        guard photoJob?.state == .failed else { return }
        photoJob = nil
    }
}
