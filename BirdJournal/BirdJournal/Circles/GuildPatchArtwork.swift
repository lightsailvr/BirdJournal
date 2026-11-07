import Pack

/// A Guild's illustration can use another available edition without changing which edition the find actually names.
/// Personal patches always keep using `patchArtState`, whose edition lookup is strict.
struct GuildPatchArtwork: Equatable {
    let setID: String?
    let state: PatchArtState
    /// Names the illustration, never the place or edition in which the member found the bird.
    var note: String? = nil
}

extension PackLibrary {
    /// Prefer the shared edition's local painting, then a local painting from the bundled set, then downloaded sets in
    /// ID order. A missing edition, an unavailable download and a set with no approved patch all take this same path.
    /// The feed can still use its matching-edition CDN thumbnail when no local painting is available.
    func guildPatchArtwork(scientificName: String, setID: String?) -> GuildPatchArtwork {
        let original = patchArtState(scientificName: scientificName, setID: setID)
        if original.art != nil { return GuildPatchArtwork(setID: setID, state: original) }
        let bundledID = bundled?.info.id
        let ordered = packs.sorted { left, right in
            if (left.info.id == bundledID) != (right.info.id == bundledID) { return left.info.id == bundledID }
            return left.info.id < right.info.id
        }
        for pack in ordered {
            guard let art = patchArt(scientificName: scientificName, setID: pack.info.id) else { continue }
            let label = editionLabel(setID: pack.info.id) ?? pack.info.name
            return GuildPatchArtwork(setID: pack.info.id, state: .painted(art), note: "Showing \(label) artwork")
        }
        return GuildPatchArtwork(setID: setID, state: original)
    }
}
