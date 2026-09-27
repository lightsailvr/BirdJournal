import Identification

/// A photo the pack holds, named so the app can load it; the pure module never touches image data.
public struct LensImage: Sendable, Hashable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

/// What the species pack knows about one species, for its card. Nil when the pack lacks the species: it is still
/// identifiable by name (spec user story 40).
public struct SpeciesProfile: Sendable, Equatable {
    public var photo: LensImage?
    /// The identification text. Empty until the pack has it (#12); the card then shows the scientific name.
    public var fieldMarks: String
    public var size: String
    public var habitat: String
    /// One line, e.g. "Photo: J. Birder, CC BY". Ignored when there is no photo.
    public var photoCredit: String

    public init(photo: LensImage?, fieldMarks: String, size: String, habitat: String, photoCredit: String) {
        self.photo = photo
        self.fieldMarks = fieldMarks
        self.size = size
        self.habitat = habitat
        self.photoCredit = photoCredit
    }
}

/// One button on a card; every button is the card's primary action.
public struct LensCardButton: Sendable, Equatable {
    public var label: String
    public var action: LensAction
}

/// One row of the species list. The app moves the selection with swipe down/up and opens the selected row on a
/// tap, so rows are not tappable on the display: the glasses hand Nav and Select to the app, not to the rows.
public struct LensListRow: Sendable, Equatable {
    /// The stack index the row stands for.
    public var index: Int
    public var commonName: String
    /// The match rate, e.g. "82%".
    public var confidence: String
    /// Whether the card has a photo (the pack knows the species) or is name-only.
    public var hasPhoto: Bool
    public var isSaved: Bool
    /// The one highlighted row, which a tap opens.
    public var isSelected: Bool

    /// The words the row spends on the lens: its name and match rate.
    public var words: Int { commonName.words + confidence.words }
}

/// One element of a card, in Display DSL terms.
public enum LensElement: Sendable, Equatable {
    /// The one-line strip at the top of a species card: species count and position.
    case status(String)
    /// The species photo, full card width, top of the card.
    case photo(LensImage)
    /// The common name in heading style with a detail (the match rate) beside it in meta style.
    case title(String, detail: String)
    case heading(String)
    case body(String)
    case meta(String)
    case button(LensCardButton)
    /// The saved mark that replaces the button once the sighting is written.
    case saved(String)
    /// The rows of the species list's current page, one selected.
    case list([LensListRow])
}

/// A card, described without the toolkit: one column of elements, sent whole as the single root `FlexBox` of a
/// Display send and scrolled by the glasses (DECISIONS.md, "Lens UI"). The elements are grouped into the screenfuls
/// they roughly lay out as, because the word budget (spec user story 24) applies per screenful.
public struct LensCard: Sendable, Equatable {
    public var screenfuls: [[LensElement]]

    public init(screenfuls: [[LensElement]]) {
        self.screenfuls = screenfuls
    }

    /// Every element of every screenful in order.
    public var elements: [LensElement] { screenfuls.flatMap { $0 } }


    /// The card's photo, if it has one.
    public var photo: LensImage? {
        for element in elements {
            if case .photo(let image) = element { return image }
        }
        return nil
    }

    /// Every word of text on the card, including button labels and list rows.
    public var wordCount: Int { elements.wordCount }
}

extension LensElement {
    /// The words the element spends on the lens.
    public var words: Int {
        switch self {
        case .status(let text), .heading(let text), .body(let text), .meta(let text), .saved(let text): text.words
        case .title(let name, let detail): name.words + detail.words
        case .button(let button): button.label.words
        case .list(let rows): rows.reduce(0) { $0 + $1.words }
        case .photo: 0
        }
    }
}

extension [LensElement] {
    /// The words a screenful spends, against `LensCardRenderer.wordBudget`.
    public var wordCount: Int { reduce(0) { $0 + $1.words } }
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
