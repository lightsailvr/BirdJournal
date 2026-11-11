import Identification

/// Maps a page and the stack to its card (spec "Card renderer", issue #24): the species list (count, one row per
/// species on the page holding the selected row, which is highlighted), the photo page (photo, name and match rate,
/// status strip and a hint) and the details page (name, field marks, size and habitat, credit and "Add to my list"
/// or the saved line), the problem page (what went wrong, what it means for the run, the way back) and the friend
/// banner (issue #67: "Maya heard a Black Phoebe · Pasadena"). Every page
/// fits the canvas. No page exceeds `wordBudget` words (spec user story 24) but the details page, whose field marks
/// are set in the small style and get `detailsWordBudget` less the fixed lines (issue #32); pack text is cut to
/// fit, field marks first.
///
/// The list's rows are in `order`, the calling section first, each calling row marked (issue #42), and paged by
/// row position so a pinned bird pushed down the list pages the view with it. A species card's strip says
/// "calling now" for its own bird, or names the bird calling now; the details page carries a strip only then.
///
/// A photo page whose species has reference clips (issue #41) points up to its sounds page, which lists the clips
/// with the next one marked, the clip's credit, and a hint saying what a tap plays next ("Tap: play its song"), and
/// while one plays, what and where ("Playing song… tap to stop", "Song on the phone…" when the glasses' speakers
/// are not the route). The viewfinder page after "Add to my list" is the camera's view, the name, and what a tap and
/// a swipe do.
///
/// The list's first row on every page, and on the empty list, is "Capture a sighting" (issue #193), highlighted in
/// place of a bird's row when the machine says so. Its viewfinder is the camera's view, the row's words and what a tap
/// and a swipe do; then "Saving the photo…" until the photo is written, and "Photo saved" / "Name it on your phone.".
///
/// Where the glasses can hear a name (issue #194) the saved photo is followed by "Say the bird's name": the photo, small,
/// the words as they are heard, and "Tap: name it later on the phone". The final words bring the birds' page: what was
/// heard (cut to `heardWordLimit` words), up to three birds with "New patch" on those the naming would sew, then "Say it
/// again" and "Name it later", one row highlighted; with no bird it says "No bird by that name" over the same two rows.
/// "Added" names the bird, "Seen", the set its patch is in and what the add earned.
public enum LensCardRenderer {
    public static let wordBudget = 40
    /// The details page's budget: forty words of field marks in the small style (the pack builder's
    /// `FIELD_MARKS_WORDS`, so pack text is never cut here) plus the name, match rate, size and habitat, credit
    /// and button. Checked on the mock lens: the page fits the 600 px canvas.
    public static let detailsWordBudget = 64
    /// The most words a card spends on its size-and-habitat line and on its credit line.
    static let metaLineBudget = 8
    /// Rows on one page of the list. The app re-sends the list on every selection move and a send starts at the top,
    /// so the rows are paged rather than scrolled, and few enough to fit the canvas with the heading. With the capture
    /// row above them (issue #193) a full page is about 500 of the canvas's 600 pixels (checked on the mock lens).
    public static let listRowsPerPage = 5
    static let saveButton = LensCardButton(label: "Add to my list", action: .save)
    static let addAnotherButton = LensCardButton(label: "Add another", action: .save)

    public static func render(
        _ page: LensPage, stack: CandidateStack, order: SpeciesListOrder, selection: Int, captureSelected: Bool = false, saved: Set<Int>,
        playing: LensPlayback? = nil, nextSounds: [Int: Int] = [:], earned: [Int: LensEarnedPatch] = [:],
        naming: LensNaming? = nil, named: LensNamedCapture? = nil, profile: (Species) -> SpeciesProfile?
    ) -> LensCard {
        switch page {
        case .list:
            return list(stack, order: order, selection: selection, captureSelected: captureSelected, saved: saved, profile: profile)
        case .species(let index):
            let candidate = stack.candidates[index]
            let profile = profile(candidate.species)
            let hint = hint(hasSounds: !(profile?.sounds ?? []).isEmpty)
            return species(candidate, position: index + 1, of: stack.count, isSaved: saved.contains(index), calling: callingText(for: index, stack: stack, order: order), hint: hint, profile: profile)
        case .sounds(let index):
            let candidate = stack.candidates[index]
            return sounds(candidate, clips: profile(candidate.species)?.sounds ?? [], next: nextSounds[index] ?? 0, playing: playing?.index == index ? playing : nil)
        case .viewfinder(let index):
            return viewfinder(stack.candidates[index])
        case .captureViewfinder:
            return captureViewfinder()
        case .captureSaving:
            return LensCard(screenfuls: [[.heading("Saving the photo…"), .meta("Swipe right: all species")]])
        case .captureSaved:
            return LensCard(screenfuls: [[.heading("Photo saved"), .body("Name it on your phone."), .meta("Tap or swipe right: all species")]])
        case .captureNaming:
            return self.naming(heard: naming?.heard ?? "")
        case .captureMatches:
            return matches(naming ?? LensNaming(capture: 0, dictation: 0))
        case .captureAdded:
            return added(named)
        case .details(let index):
            let candidate = stack.candidates[index]
            return details(candidate, isSaved: saved.contains(index), earned: earned[index], calling: callingText(for: index, stack: stack, order: order), profile: profile(candidate.species))
        case .problem(let problem):
            return self.problem(problem)
        case .friend(let banner):
            return friend(banner)
        }
    }

    /// What a species card says about calling: "calling now" for its own bird, "Now: <name>" when another bird
    /// is (the newest caller), nil when none is.
    static func callingText(for index: Int, stack: CandidateStack, order: SpeciesListOrder) -> String? {
        if order.isCalling(index: index) { return "calling now" }
        guard let newest = order.calling.first else { return nil }
        return "Now: \(stack.candidates[newest].species.commonName)"
    }

    /// The session score as a percentage, e.g. "82% match".
    public static func confidence(_ candidate: Candidate) -> String {
        "\(percent(candidate)) match"
    }

    static func percent(_ candidate: Candidate) -> String {
        "\(Int((candidate.score * 100).rounded()))%"
    }

    /// The list's first row on every page (issue #193): the way to a photo of a bird that was seen and not heard.
    public static let captureRowLabel = "Capture a sighting"

    static func list(_ stack: CandidateStack, order: SpeciesListOrder, selection: Int, captureSelected: Bool, saved: Set<Int>, profile: (Species) -> SpeciesProfile?) -> LensCard {
        let heading = switch stack.count {
        case 0: "No species yet"
        case 1: "1 species heard"
        default: "\(stack.count) species heard"
        }
        let capture = LensElement.capture(label: captureRowLabel, isSelected: captureSelected)
        guard !stack.isEmpty else {
            return LensCard(screenfuls: [[.heading(heading), .meta("Birds appear as they call."), capture]])
        }
        let indices = order.indices.count == stack.count ? order.indices : Array(stack.candidates.indices)
        let pages = (indices.count + listRowsPerPage - 1) / listRowsPerPage
        let page = (indices.firstIndex(of: selection) ?? 0) / listRowsPerPage
        let start = page * listRowsPerPage
        let rows = indices[start..<min(start + listRowsPerPage, indices.count)].map { index in
            let candidate = stack.candidates[index]
            return LensListRow(
                index: index,
                commonName: candidate.species.commonName,
                confidence: percent(candidate),
                hasPhoto: profile(candidate.species)?.photo != nil,
                isSaved: saved.contains(index),
                isSelected: index == selection && !captureSelected,
                isCalling: order.isCalling(index: index)
            )
        }
        var hint = "Swipe down to choose, tap to open."
        if pages > 1 { hint += " Page \(page + 1) of \(pages)." }
        return LensCard(screenfuls: [[.heading(heading), .meta(hint), capture, .list(rows)]])
    }

    /// The photo page's hint line: the swipes, with the sounds page above when the species has clips. Kept to the
    /// one line the plain hint takes (checked on the mock lens), so the page stays one screenful.
    static func hint(hasSounds: Bool) -> String {
        hasSounds
            ? "Up: its sounds · down: more · right: all species"
            : "Swipe down for more information · swipe right: all species"
    }

    /// The sounds page: name and match rate, one row per clip with the next one marked and the playing one sounding,
    /// the next (or playing) clip's credit, and what a tap does now. A species without clips (reached only before
    /// its profile loses them) says so.
    static func sounds(_ candidate: Candidate, clips: [LensSound], next: Int, playing: LensPlayback?) -> LensCard {
        var elements: [LensElement] = [.title(candidate.species.commonName, detail: confidence(candidate))]
        guard !clips.isEmpty else {
            elements.append(.meta("No recordings on your phone · swipe down: photo"))
            return LensCard(screenfuls: [elements])
        }
        let nextClip = clips[next % clips.count]
        let rows = clips.map { clip in
            LensSoundRow(
                label: clip.kind.noun.capitalized,
                isNext: playing == nil && clip == nextClip,
                isPlaying: playing?.sound == clip
            )
        }
        elements.append(.sounds(rows))
        let credit = (playing?.sound ?? nextClip).credit
        if !credit.isEmpty { elements.append(.meta(credit.limited(toWords: metaLineBudget))) }
        if let playing {
            let what = playing.onPhone ? "\(playing.sound.kind.noun.capitalized) on the phone" : "Playing \(playing.sound.kind.noun)"
            elements.append(.meta("\(what)… tap to stop"))
        } else {
            elements.append(.meta("Tap: play its \(nextClip.kind.noun) · down: photo"))
        }
        return LensCard(screenfuls: [elements])
    }

    /// The viewfinder page: the camera's view first, so it gets the room, then the name and what a tap and a swipe do.
    static func viewfinder(_ candidate: Candidate) -> LensCard {
        LensCard(screenfuls: [[
            .viewfinder,
            .title(candidate.species.commonName, detail: confidence(candidate)),
            .meta("Tap: take the photo · swipe: add without one"),
        ]])
    }

    /// The capture viewfinder (issue #193): the camera's view, and what a tap and a swipe do.
    static func captureViewfinder() -> LensCard {
        LensCard(screenfuls: [[
            .viewfinder,
            .heading(captureRowLabel),
            .meta("Tap: take the photo · swipe right: back"),
        ]])
    }

    // MARK: - Saying the bird's name (issue #194)

    /// The most words of what was heard a page shows: a bird's name is two or three, and a ramble must not push the rows
    /// off the page or the page over its budget.
    static let heardWordLimit = 6
    public static let sayItAgainLabel = "Say it again"
    public static let nameItLaterLabel = "Name it later"

    /// "Say the bird's name": the photo just taken, the words heard so far (or that the glasses are listening), and what
    /// a tap does.
    static func naming(heard: String) -> LensCard {
        LensCard(screenfuls: [[
            .heading("Say the bird's name"),
            .capturedPhoto,
            heard.isEmpty ? .meta("Listening…") : .body(heard.limited(toWords: heardWordLimit + 2)),
            .meta("Tap: name it later on the phone"),
        ]])
    }

    /// The birds' page: what was heard, the birds it may be with "New patch" on those the naming would sew, then the two
    /// ways on. With no bird the page says so.
    static func matches(_ naming: LensNaming) -> LensCard {
        var rows = naming.matches.map { LensChoiceRow(label: $0.commonName, detail: $0.isNewPatch ? "New patch" : nil, isSelected: false) }
        rows.append(LensChoiceRow(label: sayItAgainLabel, detail: nil, isSelected: false))
        rows.append(LensChoiceRow(label: nameItLaterLabel, detail: nil, isSelected: false))
        if rows.indices.contains(naming.highlight) { rows[naming.highlight].isSelected = true }
        var elements: [LensElement] = [.status("You said: \(naming.heard.limited(toWords: heardWordLimit))")]
        if naming.matches.isEmpty { elements.append(.heading("No bird by that name")) }
        elements.append(.choices(rows))
        elements.append(.meta("Swipe down: next · tap: choose"))
        return LensCard(screenfuls: [elements])
    }

    /// "Added": the bird, "Seen", the set its patch is in, and what the add earned, as a details page says it for an add.
    static func added(_ named: LensNamedCapture?) -> LensCard {
        var elements: [LensElement] = []
        if let named {
            elements.append(.title(named.commonName, detail: "Seen"))
            if let place = named.place, !place.isEmpty { elements.append(.meta(place.limited(toWords: metaLineBudget))) }
        }
        elements.append(.saved("Added"))
        switch named?.earned {
        case .newPatch: elements.append(.body("New patch, sewn on your phone."))
        case .seenAgain(let count): elements.append(.body("Seen again · \(count) \(count == 1 ? "time" : "times")"))
        case nil: break
        }
        elements.append(.meta("Tap or swipe right: all species"))
        return LensCard(screenfuls: [elements])
    }

    static func species(_ candidate: Candidate, position: Int, of count: Int, isSaved: Bool, calling: String?, hint: String, profile: SpeciesProfile?) -> LensCard {
        // The photo first, so nothing above it can push it below the fold on the glasses.
        var elements: [LensElement] = []
        if let photo = profile?.photo { elements.append(.photo(photo)) }
        elements.append(.title(candidate.species.commonName, detail: confidence(candidate)))
        let strip = ["\(count) species · \(position) of \(count)", isSaved ? "Added" : nil, calling].compactMap { $0 }
        elements.append(.status(strip.joined(separator: " · ")))
        elements.append(.meta(hint))
        return LensCard(screenfuls: [elements])
    }

    static func savedLine(_ candidate: Candidate, earned: LensEarnedPatch?) -> LensElement {
        switch earned {
        case .newPatch: .saved("New patch · sewn")
        case .seenAgain(let count): .saved("Seen again · \(count) \(count == 1 ? "time" : "times")")
        case nil: .saved("Added to my list")
        }
    }

    static func problem(_ problem: LensProblem) -> LensCard {
        let (heading, body) = switch problem {
        case .noLocation:
            ("No location", "Species are not filtered by place. Allow location for Featherguild in Settings on the phone.")
        case .connectionLost:
            ("Connection lost", "The glasses were out of range. Featherguild kept listening and is back on the lens.")
        case .photoNotTaken:
            ("No photo taken", "The camera was not ready, so nothing was saved. Open Capture a sighting again.")
        }
        return LensCard(screenfuls: [[.heading(heading), .body(body), .meta("Swipe right to continue")]])
    }

    /// A friend's notable find (issue #67): who found what and where, one heading, and the way back.
    static func friend(_ banner: LensFriendBanner) -> LensCard {
        LensCard(screenfuls: [[.status("A friend's find"), .heading(banner.text), .meta("Tap or swipe right to close")]])
    }

    /// A saved species shows what its latest add earned ("New patch · sewn" for the species' first sighting in its
    /// placement, else "Seen again · 8 times"; "Added to my list" until the sighting is written) and "Add another", which
    /// adds a new one. Text only: whether the lens shows a small patch image too is still the maintainer's to decide
    /// (guide page 20).
    static func details(_ candidate: Candidate, isSaved: Bool, earned: LensEarnedPatch? = nil, calling: String?, profile: SpeciesProfile?) -> LensCard {
        // The fixed lines first, then the field marks take what is left of the budget.
        var fixed: [LensElement] = []
        if let profile {
            let sizeAndHabitat = [profile.size, profile.habitat].filter { !$0.isEmpty }.joined(separator: " · ")
            if !sizeAndHabitat.isEmpty { fixed.append(.meta(sizeAndHabitat.limited(toWords: metaLineBudget))) }
            fixed.append(.meta(profile.photo == nil ? "No photo on your phone" : profile.photoCredit.limited(toWords: metaLineBudget)))
        } else {
            fixed.append(.meta("Not in your field guide"))
        }
        if isSaved {
            fixed.append(savedLine(candidate, earned: earned))
            fixed.append(.button(addAnotherButton))
        } else {
            fixed.append(.button(saveButton))
        }
        var top = [LensElement.title(candidate.species.commonName, detail: confidence(candidate))]
        if let calling { top.append(.status(calling.prefix(1).uppercased() + calling.dropFirst())) }
        let budget = detailsWordBudget - fixed.wordCount - top.wordCount
        let text = profile.map(\.fieldMarks).flatMap { $0.isEmpty ? nil : $0 } ?? candidate.species.scientificName
        return LensCard(screenfuls: [top + [.passage(text.limited(toWords: budget))] + fixed])
    }
}
