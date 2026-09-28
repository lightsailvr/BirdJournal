import Album
import Foundation
import Pack

/// What a shared sighting may carry (issue #28): the fields the birder chose, never the precise location, and the
/// attribution the picture's license asks for. Pure rules, tested without views.
enum SharePolicy {
    /// The picture on the card.
    enum Picture: Equatable {
        /// The birder's own glasses frame: theirs to share.
        case snapshot(framePath: String)
        /// A pack photo, with the credit that must travel with it.
        case reference(PackPhoto)
        /// No picture: the license does not allow redistribution for this use, or there is none.
        case none
    }

    struct Choices: Equatable {
        var includeDate = true
        var includeArea = true
        var includeNote = false
        /// Prefer the glasses snapshot over the reference photo when there is one.
        var useSnapshot = true
    }

    /// What ends up on the card and in the text.
    struct Content: Equatable {
        var commonName: String
        var scientificName: String
        var dateText: String?
        var areaText: String?
        var note: String?
        var picture: Picture
        /// The line under the picture: whose photo it is.
        var pictureCaption: String
        /// The credit the export must carry, nil for the birder's own snapshot or no picture.
        var attribution: String?
    }

    /// Licenses under which a pack photo may be redistributed on a personal, non-commercial share card with credit.
    static let shareableLicenses: Set<String> = ["CC0", "CC BY", "CC BY-NC"]

    static func mayShare(_ photo: PackPhoto) -> Bool {
        shareableLicenses.contains(photo.license)
    }

    /// - Parameters:
    ///   - area: the general place name (a city or park), never a coordinate; nil when unknown.
    static func content(
        for sighting: Sighting, commonName: String, reference: PackPhoto?, area: String?, choices: Choices,
        locale: Locale = .current, calendar: Calendar = .current
    ) -> Content {
        let picture: Picture
        let caption: String
        let attribution: String?
        if choices.useSnapshot, let frame = sighting.frameImagePath {
            picture = .snapshot(framePath: frame)
            caption = "My glasses snapshot · Bird Journal"
            attribution = nil
        } else if let reference, mayShare(reference) {
            picture = .reference(reference)
            caption = "Reference photo · \(reference.shortCredit)"
            attribution = "Photo: \(reference.creditLine), via iNaturalist \(reference.sourceURL.absoluteString)"
        } else {
            picture = .none
            caption = "Bird Journal"
            attribution = nil
        }
        let note = sighting.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Content(
            commonName: commonName,
            scientificName: sighting.scientificName,
            dateText: choices.includeDate ? sighting.confirmedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar)) : nil,
            areaText: choices.includeArea ? area : nil,
            note: choices.includeNote && !(note ?? "").isEmpty ? note : nil,
            picture: picture,
            pictureCaption: caption,
            attribution: attribution
        )
    }

    /// The text that goes with the card: the sighting in a line, the note, and the credit.
    static func text(for content: Content) -> String {
        var lines: [String] = []
        var first = "\(content.commonName) (\(content.scientificName))"
        if let date = content.dateText { first += " · \(date)" }
        if let area = content.areaText { first += " · \(area)" }
        lines.append(first)
        if let note = content.note { lines.append("“\(note)”") }
        lines.append("Heard with Bird Journal · Powered by BirdNET")
        if let attribution = content.attribution { lines.append(attribution) }
        return lines.joined(separator: "\n")
    }
}
