import Identification

/// A photo the pack holds, named so the app can load it; the pure module never touches image data.
public struct LensImage: Sendable, Hashable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

/// What the species pack knows about one species, for the photo and description pages. Nil when the pack lacks
/// the species: it is still identifiable by name (spec user story 40).
public struct SpeciesProfile: Sendable, Equatable {
    public var photo: LensImage?
    public var fieldMarks: String
    public var size: String
    public var habitat: String
    /// One line, e.g. "Photo: J. Birder, CC BY".
    public var photoCredit: String

    public init(photo: LensImage?, fieldMarks: String, size: String, habitat: String, photoCredit: String) {
        self.photo = photo
        self.fieldMarks = fieldMarks
        self.size = size
        self.habitat = habitat
        self.photoCredit = photoCredit
    }
}

/// One button on a card.
public struct LensCardButton: Sendable, Equatable {
    public var label: String
    public var action: LensButton
    public var isPrimary: Bool
}

/// One element of a card, in Display DSL terms: text in one of its three styles, or a button group.
public enum LensElement: Sendable, Equatable {
    case heading(String)
    case body(String)
    case meta(String)
    case buttons([LensCardButton])
}

/// The single root a Display send takes, described without the toolkit (DECISIONS.md: one root `FlexBox` per
/// send): an optional photo beside a column of elements. The app maps this one to one onto a `FlexBox`.
public struct LensCard: Sendable, Equatable {
    /// Shown beside the elements when the pack has one and the app can load it.
    public var photo: LensImage?
    public var elements: [LensElement]

    /// Every word of text on the card, including button labels.
    public var wordCount: Int {
        elements.reduce(0) { count, element in
            switch element {
            case .heading(let text), .body(let text), .meta(let text): count + text.words
            case .buttons(let buttons): count + buttons.reduce(0) { $0 + $1.label.words }
            }
        }
    }
}

extension String {
    var words: Int {
        split(whereSeparator: \.isWhitespace).count
    }

    /// The first `count` words, with an ellipsis when anything was cut. Zero or fewer words gives an empty string.
    func limited(toWords count: Int) -> String {
        guard count > 0 else { return "" }
        let words = split(whereSeparator: \.isWhitespace)
        guard words.count > count else { return self }
        return words.prefix(count).joined(separator: " ") + "…"
    }
}
