import Foundation

/// The offer of a set's field-guide download to a birder standing in its place (issue #223, of #206). Without the field
/// guide on the phone the set takes no sighting (issue #207), so the birder is offered it, once per set: a dismissal is
/// remembered, and nothing downloads without a tap.
public enum FieldGuideOffer {
    /// Which set's field guide to offer, if any, from facts alone: no network and no location fix.
    /// - Parameters:
    ///   - place: the set the birder is standing in, nil outside every set.
    ///   - onPhone: the packs on the phone.
    ///   - downloadable: the packs the index lists that this build can open.
    ///   - dismissed: the sets whose offer the birder has dismissed.
    public static func setToOffer(place: String?, onPhone: Set<String>, downloadable: Set<String>, dismissed: Set<String>) -> String? {
        guard let place, !onPhone.contains(place), downloadable.contains(place), !dismissed.contains(place) else { return nil }
        return place
    }
}

extension PackLibrary {
    /// The download to offer a birder standing in `place`, as the index lists it (its name, its size, what `startDownload`
    /// takes); nil when `FieldGuideOffer.setToOffer` offers none.
    /// - Parameters:
    ///   - place: the set the birder is standing in, nil outside every set.
    ///   - dismissed: the sets whose offer the birder has dismissed.
    public func fieldGuideOffer(place: String?, dismissed: Set<String>) -> PackDescriptor? {
        let listed = index?.packs ?? []
        let offered = FieldGuideOffer.setToOffer(
            place: place, onPhone: Set(packs.map(\.info.id)), downloadable: Set(listed.filter(\.isSupported).map(\.id)), dismissed: dismissed
        )
        return offered.flatMap { id in listed.first { $0.id == id } }
    }
}
