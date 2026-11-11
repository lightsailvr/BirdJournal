import Album
import Foundation
import FoundationModels
import OSLog
import Pack
import SwiftData

/// The moment a caption is written for (issue #56): the season from the date and the hemisphere, the local time of day,
/// Heard or Seen, and the place label, which is left out for a threatened species (and for one whose pack doesn't say).
struct CaptionMoment: Equatable, Sendable {
    enum Season: String, Sendable { case spring, summer, autumn, winter }
    enum TimeOfDay: String, Sendable {
        case earlyMorning = "early morning"
        case morning, afternoon, evening, night
    }

    /// Nil without a location: the hemisphere, and so the season, is unknown.
    var season: Season?
    var timeOfDay: TimeOfDay
    var method: SightingMethod
    /// The city the phone named for the sighting's place; nil without one, or for a threatened species.
    var place: String?

    /// The moment of a sighting at `date`, read in `calendar`'s time zone (the phone's, as the card's local time is).
    init(date: Date, latitude: Double?, method: SightingMethod, place: String?, isThreatened: Bool?, calendar: Calendar = .current) {
        let month = calendar.component(.month, from: date)
        let hour = calendar.component(.hour, from: date)
        season = latitude.map { Self.season(month: month, southern: $0 < 0) }
        timeOfDay = switch hour {
        case 5..<8: .earlyMorning
        case 8..<12: .morning
        case 12..<17: .afternoon
        case 17..<21: .evening
        default: .night
        }
        self.method = method
        self.place = isThreatened == false ? place : nil
    }

    /// Meteorological seasons: winter is December to February in the north, June to August in the south.
    static func season(month: Int, southern: Bool) -> Season {
        let north: Season = switch month {
        case 3...5: .spring
        case 6...8: .summer
        case 9...11: .autumn
        default: .winter
        }
        guard southern else { return north }
        return switch north {
        case .spring: .autumn
        case .summer: .winter
        case .autumn: .spring
        case .winter: .summer
        }
    }
}

/// What a caption writer is given: the species' name and fact sheet and the moment, nothing else (no note, coordinate
/// or photo).
struct CaptionRequest: Equatable, Sendable {
    var commonName: String
    var facts: [String]
    var moment: CaptionMoment

    /// The prompt the on-device model reads.
    var prompt: String {
        var lines = ["Species: \(commonName)", "", "Fact sheet:"]
        lines += facts.map { "- \($0)" }
        lines += ["", "The moment:"]
        if let season = moment.season { lines.append("- season: \(season.rawValue)") }
        lines.append("- time of day: \(moment.timeOfDay.rawValue)")
        lines.append("- the birder \(moment.method == .heard ? "heard" : "saw") it")
        if let place = moment.place { lines.append("- place: \(place)") }
        return lines.joined(separator: "\n")
    }
}

/// Writes one card caption. The app's writer is Apple's on-device Foundation Models; tests use a fake.
protocol CaptionWriter: Sendable {
    /// Stored with every caption it writes, so a later writer can tell its captions from this one's.
    var version: String { get }
    /// Whether it can write now (Apple Intelligence on, the model downloaded).
    var isAvailable: Bool { get }
    func caption(for request: CaptionRequest) async throws -> String
}

enum CaptionText {
    static let maximumWords = 18

    /// The line on a card's front: its caption, else the lore's tagline, else nothing.
    static func front(caption: CardCaption?, tagline: String?) -> String? {
        if let text = caption?.text, !text.isEmpty { return text }
        return tagline
    }

    /// The caption as stored: one line, whitespace evened, nil when empty or longer than the limit.
    static func checked(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= maximumWords else { return nil }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }
}

/// The lore's credit on the card back (issue #56): who wrote it, from what, and its license.
enum LoreText {
    static func credit(_ lore: PackLore) -> String {
        var sources: [String] = []
        if let revision = lore.wikipediaRevision {
            let id = URLComponents(url: revision, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "oldid" }?.value
            sources.append("its English Wikipedia article\(id.map { " (revision \($0))" } ?? "") by Wikipedia contributors")
        }
        sources += StatsDataset.all.filter { lore.datasets.contains($0.source) }.map { $0.source == .wingspan ? "the \($0.name)" : $0.name }
        let facts = switch sources.count {
        case 0: ""
        case 1: " Its facts come from \(sources[0])."
        default: " Its facts come from \(sources.dropLast().joined(separator: ", ")) and \(sources.last!)."
        }
        return "Written by Claude (Anthropic) from this bird's fact sheet and reviewed by hand.\(facts) Lore text: CC BY-SA 4.0."
    }
}

/// Apple's on-device model with guided generation (issue #56).
struct FoundationModelsCaptionWriter: CaptionWriter {
    static let promptVersion = 1
    let version = "apple-foundation-models caption@\(Self.promptVersion)"

    static let instructions = """
        You write the one-line caption on the front of a collectible bird card, for one moment with one bird, in a \
        mythic, legend-like voice. Use at most 18 words. You may speak of the season, the time of day, the place and \
        whether the bird was heard or seen. About the bird itself, state only what its fact sheet says: no colour, \
        food, behaviour, sound or number of your own. Do not invent people or legends. No hashtags, no emoji, no quotation marks.
        """

    @Generable
    struct Draft {
        @Guide(description: "The caption: one line of at most 18 words, in a mythic voice, true to the fact sheet.")
        var caption: String
    }

    var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    func caption(for request: CaptionRequest) async throws -> String {
        let session = LanguageModelSession(instructions: Self.instructions)
        return try await session.respond(to: request.prompt, generating: Draft.self).content.caption
    }
}

/// Writes a card's caption once, after its add (issue #56), and stores it on the sighting with its writer's version.
/// A sighting that has one is never captioned again, so reopening a card changes nothing; when the writer is unavailable
/// or fails, the sighting keeps none and the card shows the lore's tagline. A caption is for the bird the sighting was
/// when it was asked for: if the birder has changed the bird meanwhile (issue #190), the line is dropped.
@MainActor
final class Captioner {
    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "caption")

    /// What the packs know of a species: its name, its fact sheet and whether it is threatened (nil: the pack doesn't say).
    struct Species: Equatable {
        var commonName: String
        var facts: [String]
        var isThreatened: Bool?
    }

    let writer: any CaptionWriter
    let species: (_ scientificName: String) -> Species?
    /// The city for a coordinate, looked up if need be; nil when there is none.
    let placeLabel: (Coordinate) async -> String?
    var calendar = Calendar.current
    /// How many drafts may be thrown away for running long before the card keeps the tagline.
    var attempts = 2
    /// The sightings being captioned, each with the bird the line is for.
    private var inFlight: Set<InFlight> = []

    private struct InFlight: Hashable {
        let identifier: UUID
        let speciesID: String
    }

    init(writer: any CaptionWriter, species: @escaping (String) -> Species?, placeLabel: @escaping (Coordinate) async -> String?) {
        self.writer = writer
        self.species = species
        self.placeLabel = placeLabel
    }

    /// The request for a sighting; nil when no pack has the species' fact sheet.
    func request(for sighting: Sighting) async -> CaptionRequest? {
        guard let found = species(sighting.scientificName), !found.facts.isEmpty else { return nil }
        let place: String? = if found.isThreatened == false, let location = sighting.location { await placeLabel(location) } else { nil }
        let moment = CaptionMoment(
            date: sighting.confirmedAt, latitude: sighting.location?.latitude, method: sighting.method, place: place,
            isThreatened: found.isThreatened, calendar: calendar
        )
        return CaptionRequest(commonName: found.commonName, facts: found.facts, moment: moment)
    }

    /// Captions `sighting` unless it has a caption, is being captioned, or the writer can't write now.
    func caption(_ sighting: Sighting) async {
        let writing = InFlight(identifier: sighting.identifier, speciesID: sighting.speciesID)
        guard sighting.caption == nil, writer.isAvailable, !inFlight.contains(writing) else { return }
        inFlight.insert(writing)
        defer { inFlight.remove(writing) }
        guard let request = await request(for: sighting) else { return }
        for _ in 0..<attempts {
            do {
                guard let text = CaptionText.checked(try await writer.caption(for: request)) else { continue }
                guard !sighting.isDeleted, sighting.caption == nil, sighting.speciesID == writing.speciesID else { return }
                sighting.caption = CardCaption(text: text, generatorVersion: writer.version)
                try sighting.modelContext?.save()
                return
            } catch {
                Self.logger.error("caption failed, the card keeps the tagline: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        Self.logger.info("captions ran long; the card keeps the tagline")
    }
}
