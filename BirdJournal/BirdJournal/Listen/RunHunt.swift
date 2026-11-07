import Album
import Identification

/// A run as a hunt (issue #150, L1): what's waiting to be sewn here and what you already have, counted from the collection at
/// the place an add would be recorded. A bird no pack describes still counts: its review can still sew it.
struct RunHunt: Equatable {
    /// Birds heard with no patch where an add would go.
    let newPatches: Int
    /// Birds heard that already have a patch there, the ones added on this run among them.
    let alreadyHave: Int

    init(newPatches: Int, alreadyHave: Int) {
        self.newPatches = newPatches
        self.alreadyHave = alreadyHave
    }

    init(candidates: [Candidate], collection: CardCollection, at location: Coordinate?) {
        let new = candidates.count { collection.addSewsPatch(speciesID: $0.species.birdnetLabel, at: location) }
        self.init(newPatches: new, alreadyHave: candidates.count - new)
    }

    /// "1 new patch waiting": the part of the line that takes the tint. Nil when nothing's waiting.
    var waiting: String? {
        newPatches == 0 ? nil : "\(newPatches) new \(newPatches == 1 ? "patch" : "patches") waiting"
    }

    /// What follows it: " and 2 you already have", or the whole line when nothing's waiting.
    var rest: String {
        switch (newPatches, alreadyHave) {
        case (0, 0): "Nothing heard yet"
        case (0, 1): "1 bird you already have"
        case (0, let have): "\(have) birds you already have"
        case (_, 0): ""
        case (_, let have): " and \(have) you already have"
        }
    }

    /// The whole line: "1 new patch waiting and 2 you already have".
    var text: String { (waiting ?? "") + rest }

    /// The line where there's room for only the first thing it says.
    var short: String { waiting ?? rest }
}

/// How a bird's row in a run looks (issue #150, V2, L1), from the patch an add would join.
enum CandidateLook: Equatable {
    /// An add would sew its patch: the reference photo in a dashed ring, "new here" in the tint.
    case newHere
    /// You have its patch here: the patch and its count.
    case sewn(count: Int)
    /// You have its patch here and added it on this run: the patch and a check.
    case added(count: Int)

    /// A bird added on this run reads as new again where its patch doesn't reach: the run has walked into another set, or the
    /// sighting has since been deleted. An add there sews a patch, so that's what the row has to say.
    init(seenHere: Int, isAdded: Bool) {
        if seenHere == 0 {
            self = .newHere
        } else {
            self = isAdded ? .added(count: seenHere) : .sewn(count: seenHere)
        }
    }

    /// The button at the end of a row.
    enum Offer: Equatable {
        /// Adds at once and sews its patch.
        case sewIt
        /// Adds at once and ticks the patch's count.
        case add
        /// Opens the review: an add needs something to compare the bird against, and no installed pack describes this one.
        case review
        /// The check beside a bird already added, opening the review for another sighting.
        case added
    }

    func offer(isDescribed: Bool) -> Offer {
        switch self {
        case .added: .added
        case .newHere: isDescribed ? .sewIt : .review
        case .sewn: isDescribed ? .add : .review
        }
    }

    /// "new here", "seen 7 times", or "added, seen 8 times".
    var note: String {
        switch self {
        case .newHere: "new here"
        case .sewn(let count): "seen \(CardCollection.Patch.times(count))"
        case .added(let count): "added, seen \(CardCollection.Patch.times(count))"
        }
    }

    /// What VoiceOver reads for the row, one sentence for what the row shows in pictures and tint: "House Finch, calling now,
    /// new patch waiting".
    func spoken(name: String, heard: String, isCalling: Bool) -> String {
        let when = isCalling ? "calling now" : "heard \(heard)"
        return switch self {
        case .newHere: "\(name), \(when), new patch waiting"
        case .sewn(let count): "\(name), \(when), you have this patch, seen \(CardCollection.Patch.times(count))"
        case .added(let count): "\(name),\(isCalling ? " calling now," : "") added, you have this patch, seen \(CardCollection.Patch.times(count))"
        }
    }
}
