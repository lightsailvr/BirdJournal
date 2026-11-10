import Foundation

/// What an unnamed sighting's row, its group in the Collection and its delete say (issue #188, of #185), apart from the views
/// so the words are tested without drawing. "Unnamed sighting" is the copy's word for a capture: a photo of a bird waiting
/// for its name.
enum UnnamedSightingText {
    /// What the row is called until the bird has a name.
    static let title = "Unnamed sighting"
    /// The row's way on, to "Name this bird".
    static let nameIt = "Name it"
    /// The group at the top of the Collection's Sightings.
    static let toName = "To name"
    /// Under that heading.
    static let toNameNote = "Your photos of birds you haven't named yet. Each becomes a sighting once you name it."
    /// In a run's review, under the photos still unnamed: closing the review forgets the birds not added, and not these.
    static let reviewNote = "Photos you haven't named are kept. Name them any time in Collection, under Sightings."
    /// In the sheet's bar, where Cancel was: closing keeps the photo.
    static let later = "Name it later"

    static let deleteAction = "Delete photo"
    static let deleteTitle = "Delete this photo?"
    static let deleteMessage = "The unnamed sighting and its photo are deleted. This can't be undone."
    static let keep = "Keep photo"

    /// The row's line, in parts: whose photo it is and when it was taken. "just now" and minutes within the hour, as a run's
    /// rows say it; after that the time of day, and on another day the date, since one can wait for weeks.
    static func row(takenAt: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> [String] {
        let age = max(now.timeIntervalSince(takenAt), 0)
        return ["Your photo", age < 3_600 ? AgeText.text(seconds: age) : NameBirdText.taken(takenAt, now: now, calendar: calendar, locale: locale)]
    }

    /// "Unnamed sighting, Your photo, 2 min ago, Name it": the row as VoiceOver reads it.
    static func spoken(takenAt: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        NameBirdText.sentence([title] + row(takenAt: takenAt, now: now, calendar: calendar, locale: locale) + [nameIt])
    }
}
