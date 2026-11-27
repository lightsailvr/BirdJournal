import Foundation
import Observation
import Pack

/// The field-guide downloads the app offers by itself (issue #223, of #206): to a birder standing in a set whose field guide
/// isn't on the phone, that set's, once. A dismissal is remembered per set, across launches, and the set's page in the Atlas
/// keeps its ordinary Download. Nothing here downloads anything: the offer's button is the Atlas's own.
@MainActor
@Observable
final class FieldGuideOffers {
    /// The sets whose offer the birder has dismissed.
    private(set) var dismissed: Set<String>

    @ObservationIgnored private let library: PackLibrary
    @ObservationIgnored private let place: () -> String?
    @ObservationIgnored private let defaults: UserDefaults

    static let dismissedKey = "fieldGuideOffersDismissed"

    /// - Parameter place: the set the birder is standing in (`CurrentPlace.standingInSetID`), nil outside every set.
    init(library: PackLibrary, place: @escaping () -> String?, defaults: UserDefaults = .standard) {
        self.library = library
        self.place = place
        self.defaults = defaults
        #if DEBUG
        // A UI test's first launch: what an earlier run dismissed on this simulator is forgotten.
        if defaults.bool(forKey: "resetFieldGuideOffers") { defaults.removeObject(forKey: Self.dismissedKey) }
        #endif
        dismissed = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    /// The download offered where the birder is standing, as the index lists it; nil when there's none to offer.
    var here: PackDescriptor? {
        library.fieldGuideOffer(place: place(), dismissed: dismissed)
    }

    /// The offer for one set, on its page in the Atlas and under "Your local set": `here`, when that's the set the birder is standing in.
    func offer(forSet id: String) -> PackDescriptor? {
        here.flatMap { $0.id == id ? $0 : nil }
    }

    /// "Not now": the set isn't offered again, on this launch or a later one.
    func dismiss(setID: String) {
        guard dismissed.insert(setID).inserted else { return }
        defaults.set(dismissed.sorted(), forKey: Self.dismissedKey)
    }
}
