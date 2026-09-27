import Identification

/// Maps a page and the stack to the card to send (spec "Card renderer"): photo (image, common name, confidence),
/// description (field marks, size, habitat, credit), confirm (Save primary), saved, listening (count). No page
/// exceeds `wordBudget` words (spec user story 24): a long field-marks text is cut to fit.
public enum LensCardRenderer {
    public static let wordBudget = 40

    public static func render(_ page: LensPage, stack: CandidateStack, profile: (Species) -> SpeciesProfile?) -> LensCard {
        switch page {
        case .listening:
            return listening(count: stack.count)
        case .photo(let index):
            let candidate = stack.candidates[index]
            return photo(candidate, position: index + 1, of: stack.count, profile: profile(candidate.species))
        case .description(let index):
            let candidate = stack.candidates[index]
            return description(candidate, profile: profile(candidate.species))
        case .confirm(let index):
            return confirm(stack.candidates[index])
        case .saved(let index):
            return saved(stack.candidates[index])
        }
    }

    static func listening(count: Int) -> LensCard {
        let body = switch count {
        case 0: "No species yet"
        case 1: "1 species heard"
        default: "\(count) species heard"
        }
        return LensCard(layout: .column, elements: [
            .heading("Listening"),
            .body(body),
            .meta(count == 0 ? "Cards appear as birds call." : "Swipe left to see them."),
        ])
    }

    static func photo(_ candidate: Candidate, position: Int, of count: Int, profile: SpeciesProfile?) -> LensCard {
        var elements: [LensElement] = []
        if let photo = profile?.photo { elements.append(.image(photo)) }
        elements.append(.heading(candidate.species.commonName))
        elements.append(.body(confidence(candidate)))
        elements.append(.meta(profile?.photo == nil ? "\(position) of \(count) · no photo in your pack" : "\(position) of \(count)"))
        return LensCard(layout: profile?.photo == nil ? .column : .photoBeside, elements: elements)
    }

    static func description(_ candidate: Candidate, profile: SpeciesProfile?) -> LensCard {
        let heading = LensElement.heading(candidate.species.commonName)
        guard let profile else {
            return LensCard(layout: .column, elements: [
                heading,
                .body(candidate.species.scientificName),
                .meta("No description in your pack."),
            ])
        }
        let fixed: [LensElement] = [
            heading,
            .meta("\(profile.size) · \(profile.habitat)"),
            .meta(profile.photoCredit),
        ]
        let budget = wordBudget - LensCard(layout: .column, elements: fixed).wordCount
        var elements = fixed
        elements.insert(.body(profile.fieldMarks.limited(toWords: budget)), at: 1)
        return LensCard(layout: .column, elements: elements)
    }

    static func confirm(_ candidate: Candidate) -> LensCard {
        LensCard(layout: .column, elements: [
            .heading("Save this sighting?"),
            .body(candidate.species.commonName),
            .meta(confidence(candidate)),
            .buttons([
                LensCardButton(label: "Save", action: .save, isPrimary: true),
                LensCardButton(label: "Cancel", action: .cancel, isPrimary: false),
            ]),
        ])
    }

    static func saved(_ candidate: Candidate) -> LensCard {
        LensCard(layout: .column, elements: [
            .heading("Saved"),
            .body(candidate.species.commonName),
            .meta("Swipe up to keep listening."),
        ])
    }

    /// The session score as a percentage, e.g. "82% match".
    static func confidence(_ candidate: Candidate) -> String {
        "\(Int((candidate.score * 100).rounded()))% match"
    }
}

extension String {
    /// The first `count` words, with an ellipsis when anything was cut. Zero or fewer words gives an empty string.
    func limited(toWords count: Int) -> String {
        let words = split(whereSeparator: \.isWhitespace)
        guard count > 0 else { return "" }
        guard words.count > count else { return self }
        return words.prefix(count).joined(separator: " ") + "…"
    }
}
