import Identification

/// Maps a page and the stack to the card to send (spec "Card renderer"): photo (image, common name, confidence),
/// description (field marks, size, habitat, credit), confirm (Save primary), saved, listening (count). No page
/// exceeds `wordBudget` words (spec user story 24): pack text is cut to fit, field marks first.
public enum LensCardRenderer {
    public static let wordBudget = 40
    /// The most words a description page spends on its size-and-habitat line and on its credit line.
    static let metaLineBudget = 8

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

    /// The session score as a percentage, e.g. "82% match".
    public static func confidence(_ candidate: Candidate) -> String {
        "\(Int((candidate.score * 100).rounded()))% match"
    }

    static func listening(count: Int) -> LensCard {
        let body = switch count {
        case 0: "No species yet"
        case 1: "1 species heard"
        default: "\(count) species heard"
        }
        return LensCard(photo: nil, elements: [
            .heading("Listening"),
            .body(body),
            .meta(count == 0 ? "Cards appear as birds call." : "Swipe left to see them."),
        ])
    }

    static func photo(_ candidate: Candidate, position: Int, of count: Int, profile: SpeciesProfile?) -> LensCard {
        let photo = profile?.photo
        return LensCard(photo: photo, elements: [
            .heading(candidate.species.commonName),
            .body(confidence(candidate)),
            .meta(photo == nil ? "\(position) of \(count) · no photo in your pack" : "\(position) of \(count)"),
        ])
    }

    static func description(_ candidate: Candidate, profile: SpeciesProfile?) -> LensCard {
        let heading = LensElement.heading(candidate.species.commonName)
        guard let profile else {
            return LensCard(photo: nil, elements: [
                heading,
                .body(candidate.species.scientificName),
                .meta("No description in your pack."),
            ])
        }
        let fixed: [LensElement] = [
            heading,
            .meta("\(profile.size) · \(profile.habitat)".limited(toWords: metaLineBudget)),
            .meta(profile.photoCredit.limited(toWords: metaLineBudget)),
        ]
        let budget = wordBudget - LensCard(photo: nil, elements: fixed).wordCount
        var elements = fixed
        elements.insert(.body(profile.fieldMarks.limited(toWords: budget)), at: 1)
        return LensCard(photo: nil, elements: elements)
    }

    static func confirm(_ candidate: Candidate) -> LensCard {
        LensCard(photo: nil, elements: [
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
        LensCard(photo: nil, elements: [
            .heading("Saved"),
            .body(candidate.species.commonName),
            .meta("Swipe up to keep listening."),
        ])
    }
}
