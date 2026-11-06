import Album
import Observation
import Pack
import UIKit

/// Where the app thinks the birder is (issue #150): one set, which the Listen painting shows, "Your local set" names and the
/// app's tint follows. It's remembered, so a launch shows the last painting at once, and read again each time Listen appears.
/// Only the set is remembered: the coordinate that picked it is used once, and neither stored nor sent.
@MainActor
@Observable
final class CurrentPlace {
    /// The set shown.
    private(set) var setID: String?
    /// Its cover, decoded: `setID` and this change together, so the painting never lags the words and the tint.
    private(set) var painting: UIImage?

    @ObservationIgnored private var shownCover: SetCover?
    @ObservationIgnored private let library: PackLibrary
    @ObservationIgnored private let collection: () -> CardCollection
    @ObservationIgnored private let location: any LocationProvider
    @ObservationIgnored private let defaults: UserDefaults

    static let rememberedKey = "currentPlaceSetID"

    /// Reads the remembered set and decodes its cover here, on the main actor at launch, so the first frame already has it. With
    /// nothing remembered, or a set the phone no longer knows, it's the choice with no coordinate.
    init(library: PackLibrary, collection: @escaping () -> CardCollection, location: any LocationProvider, defaults: UserDefaults = .standard) {
        self.library = library
        self.collection = collection
        self.location = location
        self.defaults = defaults
        let remembered = defaults.string(forKey: Self.rememberedKey).flatMap { id in library.sets.contains { $0.id == id } ? id : nil }
        let id = remembered ?? LocalSet.choose(coordinate: nil, in: collection())
        setID = id
        shownCover = id.flatMap(library.cover(setID:))
        painting = SetCoverImage.decoded(shownCover)
    }

    /// One read of the last known position, and the set it picks. If that's a different set (or a better cover of the same one),
    /// its cover decodes off the main actor and then everything changes at once.
    func refresh() async {
        guard let id = LocalSet.choose(coordinate: location.lastKnownCoordinate(), in: collection()) else { return }
        let cover = library.cover(setID: id)
        guard id != setID || cover != shownCover else { return }
        let image = await SetCoverImage.load(cover)
        guard !Task.isCancelled else { return }
        setID = id
        shownCover = cover
        painting = image
        defaults.set(id, forKey: Self.rememberedKey)
    }
}
