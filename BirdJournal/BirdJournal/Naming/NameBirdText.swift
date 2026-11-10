import Album
import Foundation

/// What "Name this bird" and the run's "Seen this run" rows say (issue #186), apart from the views so the words are tested
/// without drawing: on screen the parts of a line are set apart with a middle dot, and VoiceOver hears them as a sentence.
enum NameBirdText {
    /// A bird's line among the results, in parts: where its patch would go, and whether one is there already. A field
    /// guide's bird says "New to you here" until it has a patch; any other bird is marked by its placement alone,
    /// Uncharted unless a set the phone knows lists it.
    static func status(placement: CardPlacement, seenHere: Int, isInFieldGuide: Bool) -> [String] {
        if seenHere > 0 { return [placement.setName, "Seen \(CardCollection.Patch.times(seenHere)) here"] }
        return isInFieldGuide ? [placement.setName, "New to you here"] : [placement.setName]
    }

    /// "Black Phoebe, Los Angeles, New to you here": a result as VoiceOver reads it.
    static func spoken(name: String, status: [String]) -> String {
        sentence([name] + status)
    }

    /// The pinned button: "Add and sew patch" when the chosen bird has no patch where the sighting would go, else "Add
    /// sighting"; that too before a bird is chosen, when it can't be pressed.
    static func addTitle(seenHere: Int?) -> String {
        seenHere == 0 ? "Add and sew patch" : "Add sighting"
    }

    /// The line under the button: what choosing did, or what to do.
    static func addNote(name: String?, seenHere: Int) -> String {
        guard let name else { return "Choose the bird in your photo." }
        return seenHere == 0 ? "\(name), new to you here." : "\(name), seen \(CardCollection.Patch.times(seenHere)) here."
    }

    /// Under the search field before anything is typed, when only the field guides' birds are listed.
    static let searchHint = "Search by a bird's common or scientific name. Any bird BirdNET knows can be named, not only those in your field guides."

    /// "And 212 more. Keep typing to narrow them down."; nil when every match is listed.
    static func more(_ count: Int) -> String? {
        count > 0 ? "And \(count) more. Keep typing to narrow them down." : nil
    }

    /// A seen bird's line on the run, in parts: "Seen", "your photo", "New patch" for the sighting that sewed its patch, and
    /// its patch's count for a repeat.
    static func seenRow(sewedPatch: Bool, count: Int) -> [String] {
        sewedPatch ? ["Seen", "your photo", "New patch"] : ["Seen \(CardCollection.Patch.times(max(count, 1))) here", "your photo"]
    }

    /// Parts as one line on screen: "Seen · your photo · New patch".
    static func line(_ parts: [String]) -> String {
        parts.joined(separator: " · ")
    }

    /// Parts as VoiceOver reads them: with commas, since it reads a middle dot aloud or not at all.
    static func sentence(_ parts: [String]) -> String {
        parts.joined(separator: ", ")
    }

    /// When the photo was taken, under it: "Today, 9:41 AM", or the date and time on another day.
    static func taken(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        time.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(date.formatted(time))" }
        var day = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)
        day.timeZone = calendar.timeZone
        return date.formatted(day)
    }

    /// Where the sighting will be recorded, under the photo: "Near Griffith Park, Los Angeles", the coordinate until the name
    /// is known, or that there is no place.
    static func place(location: Coordinate?, name: String?) -> String {
        guard let location else { return "Place not recorded" }
        return "Near \(name ?? location.formatted)"
    }
}
