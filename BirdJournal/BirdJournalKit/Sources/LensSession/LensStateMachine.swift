import Identification

/// A page shown on the lens. Indices refer to the session's candidate stack, which only ever appends. Every page
/// fits the canvas: the glasses do not scroll a view while the app subscribes to Inputs (DECISIONS.md, "Lens UI").
public enum LensPage: Sendable, Hashable {
    /// Root page: every species heard this session, one row each, with the machine's `selection` highlighted.
    case list
    /// The photo page for the species at `index`: photo, name and match rate, status strip, hint.
    case species(index: Int)
    /// The details page under the photo page: identification text, credit and the "Add to my list" action (or its
    /// saved mark).
    case details(index: Int)
    /// The sounds page above the photo page: the species' reference clips, which a tap here plays (issue #41). A
    /// page of its own so a swipe the band reads as a tap elsewhere never starts one.
    case sounds(index: Int)
    /// The camera's view after "Add to my list", to frame the bird: a tap takes the photo and adds it, any swipe
    /// adds it without one.
    case viewfinder(index: Int)
    /// The camera's view after "Capture a sighting" on the list (issue #193), to frame a bird that was seen and not
    /// heard: a tap takes the photo, any swipe (or Back) returns to the list with nothing saved.
    case captureViewfinder
    /// After the tap on the capture viewfinder, until the run says the photo is written: "Saving the photo…". Swipe right
    /// (or Back) returns to the list, and the photo is saved all the same.
    case captureSaving
    /// The photo is on the phone as an unnamed sighting: "Photo saved. Name it on your phone." A tap or swipe right (or
    /// Back) returns to the list. Where the capture ends when no name is said: "Name it later", silence, no speech on the
    /// glasses, anything going wrong (issue #194).
    case captureSaved
    /// "Say the bird's name" (issue #194): the photo is saved and the glasses are listening; the words show as they are
    /// heard (`LensStateMachine.naming`). A tap names it later, on the phone.
    case captureNaming
    /// What was heard and the birds it may be, the first highlighted, then "Say it again" and "Name it later". Swipe down
    /// and up move the highlight and a tap chooses.
    case captureMatches
    /// The photo is named and its sighting written: "Added", with what it earned (`LensStateMachine.named`). A tap or
    /// swipe right (or Back) returns to the list.
    case captureAdded
    /// A problem the run wants the wearer to know about, over whichever page they were on (issue #10). Swipe right,
    /// Back or a tap is the way back to that page.
    case problem(LensProblem)
    /// A friend's notable find (issue #67), over the species list or a photo page only. A tap or swipe right (or
    /// Back) dismisses it and returns to the page it covers.
    case friend(LensFriendBanner)

    /// The stack index the page is about, nil on the root, a problem page and a friend banner.
    public var index: Int? {
        switch self {
        case .list, .captureViewfinder, .captureSaving, .captureSaved, .captureNaming, .captureMatches, .captureAdded, .problem, .friend: nil
        case .species(let index), .details(let index), .sounds(let index), .viewfinder(let index): index
        }
    }

    /// Whether the page shows the camera's view, the add's or the capture's: the adapter keeps it fed with frames, and a
    /// tap right behind the press that opened it is that press again.
    public var isViewfinder: Bool {
        switch self {
        case .viewfinder, .captureViewfinder: true
        case .list, .species, .details, .sounds, .captureSaving, .captureSaved, .captureNaming, .captureMatches, .captureAdded, .problem, .friend: false
        }
    }

    /// Whether a tap on the page would undo or skip what the press that opened it was for. The hardware can deliver one
    /// press twice (a click and a select), so the adapter, which has a clock, drops a tap that lands on such a page right
    /// behind the press that opened it. The viewfinders, where the echo would take the photo; "Say the bird's name",
    /// which "Say it again" opens and where a tap is "Name it later"; and "Photo saved" and "Added", which a tap opens
    /// and a tap closes before they are read.
    public var guardsItsTap: Bool {
        switch self {
        case .viewfinder, .captureViewfinder, .captureNaming, .captureSaved, .captureAdded: true
        case .list, .species, .details, .sounds, .captureSaving, .captureMatches, .problem, .friend: false
        }
    }
}

/// A bird the words said to the glasses may name (issue #194), as the lens lists it.
public struct LensNameMatch: Sendable, Hashable {
    /// Tells the bird to whoever names the photo: its scientific name.
    public var id: String
    public var commonName: String
    /// Naming the photo as this bird would sew its patch where the photo was taken.
    public var isNewPatch: Bool

    public init(id: String, commonName: String, isNewPatch: Bool) {
        self.id = id
        self.commonName = commonName
        self.isNewPatch = isNewPatch
    }
}

/// A photo taken from the lens being named by voice (issue #194): what the "Say the bird's name" page and the page of
/// birds after it show.
public struct LensNaming: Sendable, Hashable {
    /// What the highlighted row of the birds' page is.
    public enum Choice: Sendable, Hashable {
        case match(LensNameMatch)
        /// "Say it again".
        case again
        /// "Name it later".
        case later
    }

    /// The capture being named.
    public var capture: Int
    /// Counts up each time the lens listens, so the late words of an earlier dictation are told apart.
    public var dictation: Int
    /// The words heard so far; the final ones once the birds are listed.
    public var heard = ""
    /// The birds the final words may name, the closest first; none while listening, and when no bird answers to them.
    public var matches: [LensNameMatch] = []
    /// The highlighted row of the birds' page: a bird, then "Say it again", then "Name it later".
    public var highlight = 0
    /// A bird was chosen and its sighting is being written: nothing moves until the adapter says how it went.
    public var isNaming = false

    public init(capture: Int, dictation: Int) {
        self.capture = capture
        self.dictation = dictation
    }

    /// The most birds the birds' page lists.
    public static let matchLimit = 3

    /// How many rows the birds' page has.
    public var rows: Int { matches.count + 2 }

    /// What a tap on the birds' page chooses.
    public var choice: Choice {
        if highlight < matches.count { return .match(matches[highlight]) }
        return highlight == matches.count ? .again : .later
    }
}

/// A photo named from the lens (issue #194), as the "Added" page says it.
public struct LensNamedCapture: Sendable, Hashable {
    public var commonName: String
    /// The set its patch is in, e.g. "Los Angeles"; nil when it is in none (Uncharted is no place to name) or it is not
    /// known, and the page then has no such line.
    public var place: String?
    public var earned: LensEarnedPatch

    public init(commonName: String, place: String?, earned: LensEarnedPatch) {
        self.commonName = commonName
        self.place = place
        self.earned = earned
    }
}

/// How naming a capture's photo from the lens went (issue #194), as whoever writes the sighting tells the adapter.
public enum LensNamingOutcome: Sendable, Hashable {
    /// The sighting is written: what the "Added" page says.
    case named(LensNamedCapture)
    /// It could not be written. The photo is still on the phone, unnamed.
    case notWritten
    /// There was no photo left to name: the phone named or deleted it while the lens showed the birds.
    case gone
}

/// What can go wrong with a run while the lens is still reachable (issue #10).
public enum LensProblem: Sendable, Hashable {
    /// No location fix: identification runs without the regional filter.
    case noLocation
    /// The link to the glasses dropped and came back; the run kept listening meanwhile.
    case connectionLost
    /// The tap on the capture viewfinder took no photo (issue #193): none came from the camera and it had shown no
    /// picture to stand in, or the photo could not be written. Nothing is on the phone.
    case photoNotTaken
    /// The wearer chose a bird for a photo the phone had named or deleted meanwhile (issue #194): there is nothing left
    /// to name, so the lens does not say the photo waits on the phone.
    case photoGone
}

/// A friend's notable find as the lens shows it (issue #67): "Maya heard a Black Phoebe · Pasadena".
public struct LensFriendBanner: Sendable, Hashable {
    /// How the friend found the bird, as the line says it.
    public enum Method: Sendable, Hashable {
        case heard
        case saw
    }

    /// Tells one find from another (the friend and their sighting): the same find delivered twice is one banner.
    public var id: String
    /// The friend's first name, or "A friend".
    public var friendName: String
    public var method: Method
    /// The species' common name, e.g. "Black Phoebe".
    public var speciesName: String
    /// The city, "a secret spot", or nil when the find has no place.
    public var place: String?

    public init(id: String, friendName: String, method: Method, speciesName: String, place: String?) {
        self.id = id
        self.friendName = friendName
        self.method = method
        self.speciesName = speciesName
        self.place = place
    }

    /// "Maya heard a Black Phoebe · Pasadena"; without a place the line ends at the bird.
    public var text: String {
        let verb = switch method {
        case .heard: "heard"
        case .saw: "saw"
        }
        let article = speciesName.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a"
        let find = "\(friendName) \(verb) \(article) \(speciesName)"
        guard let place, !place.isEmpty else { return find }
        return "\(find) · \(place)"
    }
}

/// Semantic input events as the app sees them. Swipes arrive as Nav events and taps as Select events from the
/// Neural Band. Real glasses do not deliver `back` (DAT 1.0.0 Inputs docs, "Current limitations"): the system's
/// back gesture ends the display session instead. The rule is here for the mock and for when hardware delivers it.
public enum LensGesture: Sendable, Hashable, CaseIterable {
    case swipeLeft
    case swipeRight
    case swipeUp
    case swipeDown
    case tap
    case back

    /// The gesture as the wearer performed it, for the phone log.
    public var name: String {
        switch self {
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .swipeUp: "Swipe up"
        case .swipeDown: "Swipe down"
        case .tap: "Tap"
        case .back: "Back"
        }
    }
}

/// A tappable element on a lens card, activated through the Display rather than Inputs.
public enum LensAction: Sendable, Hashable {
    /// The "Add to my list" button on a details page.
    case save
}

/// A reference clip started from a sounds page (issue #41), until it ends, is stopped or the wearer moves on.
public struct LensPlayback: Sendable, Hashable {
    /// Counts up with every start, so news of a clip that has since been replaced is told apart.
    public var id: Int
    /// The stack index of the species whose sounds page started it.
    public var index: Int
    public var sound: LensSound
    /// The glasses' speakers were not the audio route, so the clip plays on the phone and the page says so.
    public var onPhone: Bool
}

/// What an add earned, known once its sighting is written (issues #132, #135): a new patch, the species' first sighting
/// in its placement; or another sighting of a patch the birder has, with the patch's count now.
public enum LensEarnedPatch: Sendable, Hashable {
    case newPatch
    case seenAgain(count: Int)
}

/// What the adapter must do after an event, besides rendering the new page.
public enum LensEffect: Sendable, Equatable {
    /// "Add to my list" opened the viewfinder: show the camera's view until the wearer taps or swipes.
    case openViewfinder(Candidate)
    /// "Capture a sighting" opened its viewfinder (issue #193): show the camera's view until the wearer taps or swipes.
    case openCaptureViewfinder
    /// A tap on the capture viewfinder: take a photo now and write it as an unnamed sighting, then tell the machine how
    /// it went with `captureSaved(_:)` or `captureFailed(_:)`. The number tells one capture from the next.
    case capturePhoto(Int)
    /// "Say the bird's name" is the page (issue #194): listen for the name of capture `capture`, and tell the machine
    /// what is heard with `heard(_:dictation:)`, `matched(_:_:dictation:)` and `dictationEnded(_:)` and this dictation's
    /// number. The adapter listens only while that page is the page.
    case listenForName(dictation: Int, capture: Int)
    /// A tap on a bird of the birds' page: name the capture's photo as it, which writes its sighting, then tell the
    /// machine how it went with `captureNamed(_:as:)` or `captureNotNamed(_:)`.
    case nameCapture(Int, as: LensNameMatch)
    /// A tap on the viewfinder: take a photo now and write the Sighting with it.
    case takePhoto(Candidate)
    /// A swipe off the viewfinder: write the Sighting without a photo.
    case saveSighting(Candidate)
    /// Back on the root: end the glasses session.
    case endSession
    /// A tap on a sounds page: play the species' next reference clip, replacing nothing (only one plays at a time).
    case playSound(Candidate, LensPlayback)
    /// Stop the clip playing: a tap while it plays, a swipe, Back, or a problem page over it.
    case stopSound
}

/// Pure lens state machine (spec "Lens session"): folds `CandidateStack` updates and semantic input events into
/// the page to render and at most one side effect per event.
///
/// Page map (DECISIONS.md, "Lens UI", issue #24). The list is a menu the app drives, because the glasses hand Nav
/// and Select to an app that subscribes to Inputs instead of moving focus between tappable rows (and do not scroll
/// a view either): swipe down/up move the highlight, and a tap or swipe left opens the highlighted species' photo
/// page. From the photo page swipe down opens the details page and swipe up the sounds page, and the opposite swipe
/// returns; on any of the three, swipe left is the next species' photo and swipe right is back to the list (the only
/// way back on real glasses, which do not deliver Back). A tap on the photo page does nothing: the band can read a
/// swipe as a tap, and the photo page is where the wearer swipes most. A tap or the button on the details page is
/// "Add to my list", which opens the viewfinder: a tap there takes the photo and adds the bird, any swipe (or Back)
/// adds it without one, and either returns to the details page with the saved mark. A tap on the sounds page plays
/// the species' reference clips (issue #41), the song first; a tap while one plays stops it, and the next tap plays
/// the call, round again. Any other gesture, and a problem page, stops a clip as it moves on. The stack never
/// reorders and new species append at the end, so an update never moves the page the wearer is on. A reported problem covers the current page until swipe right, Back or a
/// tap returns there (issue #10).
///
/// "Capture a sighting" (issue #193) is the row above the first bird on every page of the list, for a bird that was
/// seen and not heard. The highlight reaches it by one swipe up from the first bird, and leaves it by a swipe down or
/// right, back onto the first bird; on an empty list it is the highlighted row. A tap or swipe left on it opens the
/// capture viewfinder: a tap there takes the photo (`LensEffect.capturePhoto`), and any swipe (or Back) returns to the
/// list with nothing saved. After the tap the lens waits on the saving page until the adapter says the photo is
/// written (`captureSaved(_:dictation:)`) or that there is none (`captureFailed(_:)`: a problem page). On the saved
/// page ("Photo saved. Name it on your phone.") a tap, swipe right or Back returns to the list, the highlight still on
/// the row; the wait can be left by swipe right or Back, and the photo is saved all the same.
///
/// Where the glasses can hear a name (issue #194) the photo's saving leads to "Say the bird's name" instead
/// (`LensEffect.listenForName`): the words show as they are heard (`heard(_:dictation:)`), and the final ones bring the
/// birds they may be (`matched(_:_:dictation:)`), the closest highlighted, above "Say it again" and "Name it later".
/// Swipe down and up move the highlight; a tap on a bird names the photo (`LensEffect.nameCapture`), and once its
/// sighting is written (`captureNamed(_:as:)`) the lens says "Added" and what it earned. Words no bird answers to say so
/// over the same two rows. Nothing here can lose the photo: a tap while listening, "Name it later", a dictation that ends
/// with nothing to match (`dictationEnded(_:)`), a name that could not be written (`captureNotNamed(_:)`) and a problem
/// page over the listening all end on the saved page, and swipe right or Back returns to the list from any of them.
///
/// A friend's notable find (issue #67) is a banner page like the problem page, shown only over the species list or a
/// photo page. Anywhere else (a viewfinder, a details page, a sounds page, a capture's pages, a problem page) it is held and shown
/// when the wearer lands back on the list or a photo page. One at a time: a newer find replaces the banner showing
/// or the one held, and a banner held for more than `bannerHoldLimit` seconds after it arrived is dropped
/// (`expireBanner(at:)`). A tap or swipe right (or Back) dismisses it; the other swipes do nothing there.
///
/// The list shows the stack in `order` (issue #42): calling birds first, then the rest most recently heard first.
/// The highlight is unpinned until the wearer swipes: it sits on row one, so the calling bird is the highlighted
/// row and a tap opens it. Swipe down or up pins it to a species, and it stays on that bird as the list moves under
/// it; swipe right on the list unpins it. Opening a card leaves the pin as it is; paging to the next species on a
/// card pins to that species, so coming back lands on it.
public struct LensStateMachine: Sendable, Equatable {
    public private(set) var page: LensPage = .list
    /// The page a problem page covers, for the way back.
    private var coveredPage: LensPage = .list
    /// The candidates the pages index into, in admission order.
    public private(set) var stack = CandidateStack()
    /// The order the list shows the stack in, as of the last update.
    public private(set) var order = SpeciesListOrder()
    /// The species the highlight is pinned to by a swipe, nil while it follows row one.
    public private(set) var pinnedSpecies: Species?
    /// Whether a swipe up from the first bird put the highlight on the "Capture a sighting" row.
    private var captureRowSelected = false
    /// Photos taken from the capture viewfinder so far, for their numbers.
    private var captures = 0
    /// The capture whose photo the "Saving the photo…" page is waiting for, nil when none is.
    private var awaitedCapture: Int?
    /// The photo being named by voice, on "Say the bird's name" and the birds' page (issue #194); nil elsewhere.
    public private(set) var naming: LensNaming?
    /// The photo just named, on the "Added" page; nil elsewhere.
    public private(set) var named: LensNamedCapture?
    /// Dictations started so far, for their numbers.
    private var dictations = 0
    /// Stack indices with a sighting saved this session; their pages show the saved mark. A later tap on a saved
    /// details page ("Add another") saves another sighting; one press that hardware delivers twice, as a click and a
    /// select, is deduplicated by the adapter, which has a clock.
    public private(set) var savedIndices: Set<Int> = []
    /// Per stack index, what its latest written add earned; the details page's saved line names it.
    public private(set) var earnedPatches: [Int: LensEarnedPatch] = [:]
    /// The clip playing from a sounds page, nil when none is.
    public private(set) var playing: LensPlayback?
    /// Per stack index, the position in its species' clips of the one the next tap plays (0, the song, when absent).
    public private(set) var nextSounds: [Int: Int] = [:]
    /// Playbacks started this session, for their ids.
    private var playbacks = 0
    /// The friend banner waiting for the list or a photo page, nil when none is.
    public private(set) var heldBanner: LensFriendBanner?
    /// When the current banner (held or showing) arrived, on the clock `friendFound(_:at:)` was given; infinity for a
    /// banner the wearer has already had on the lens, which a problem or a new session pushed back (it never expires).
    private var bannerArrivedAt: Double = 0
    /// Every find a banner was made for, so the same find delivered again (even after a dismissal) shows nothing.
    private var bannerIDs: Set<String> = []

    /// How long a held friend banner waits for the list or a photo page before it is dropped: five minutes.
    public static let bannerHoldLimit: Double = 300

    public init() {}

    /// The candidate the current page is about, nil on the list.
    public var currentCandidate: Candidate? {
        page.index.map { stack.candidates[$0] }
    }

    /// The highlighted row of the list as a stack index: the pinned species, else row one (0 on an empty list).
    public var selection: Int {
        if let pinnedSpecies, let index = stack.candidates.firstIndex(where: { $0.species == pinnedSpecies }) {
            return index
        }
        return order.indices.first ?? 0
    }

    /// The species heard, in the order the list shows them: what "heard this run" means to whoever ranks a name said
    /// to the glasses (issue #194).
    public var listedSpecies: [Species] {
        order.listed(stack).map { stack.candidates[$0].species }
    }

    /// Whether the highlight is on the "Capture a sighting" row above the birds (issue #193) rather than on `selection`:
    /// after a swipe up from the first bird, and on an empty list, where it is the only row.
    public var isCaptureRowHighlighted: Bool {
        captureRowSelected || stack.isEmpty
    }

    // MARK: - Stack

    /// Takes the latest stack at session time `time` (seconds since the run started, the clock `Candidate` times
    /// are on). Returns true if anything the pages show changed: the stack, or the list order, which also moves when a
    /// calling marker lapses with the stack unchanged. A stack that does not continue the current one (a new
    /// session) restarts on the list with nothing saved and nothing pinned, so no page can index past the end.
    @discardableResult
    public mutating func update(with stack: CandidateStack, at time: Double) -> Bool {
        let stackChanged = stack != self.stack
        let continues = stack.count >= self.stack.count
            && zip(stack.candidates, self.stack.candidates).allSatisfy { $0.species == $1.species }
        self.stack = stack
        if !continues {
            // A banner showing survives the new session: it waits a moment as held and is shown on the list.
            if case .friend(let banner) = page { holdAgain(banner) }
            page = .list
            coveredPage = .list
            pinnedSpecies = nil
            captureRowSelected = false
            awaitedCapture = nil
            naming = nil
            named = nil
            savedIndices = []
            earnedPatches = [:]
            playing = nil
            nextSounds = [:]
            order = SpeciesListOrder()
        }
        let previousOrder = order
        order.update(with: stack, at: time)
        if !continues { presentHeldBanner() }
        return stackChanged || order != previousOrder
    }

    // MARK: - Problems

    /// Shows `problem` over the current page (or in place of the problem already showing) until the wearer swipes
    /// right, taps or goes back. A clip playing under it is stopped.
    @discardableResult
    public mutating func report(_ problem: LensProblem) -> LensEffect? {
        // A banner showing gives way to the problem and is held again, so it comes back after it.
        if case .friend(let banner) = page {
            holdAgain(banner)
            page = coveredPage
        }
        if case .problem = page {} else { coveredPage = page }
        // Nobody says a name to a problem page: the dictation ends, and the photo waits on the phone.
        if coveredPage == .captureNaming {
            coveredPage = .captureSaved
            naming = nil
        }
        page = .problem(problem)
        return stopPlaying()
    }

    // MARK: - Gestures

    /// Applies a gesture to the current page. Gestures with no meaning on the current page are ignored. `sounds`
    /// gives a species' reference clips in the order a sounds page's taps play them.
    public mutating func apply(_ gesture: LensGesture, sounds: (Species) -> [LensSound] = { _ in [] }) -> LensEffect? {
        if gesture != .tap, let stop = stopPlaying() {
            // A clip plays only on a sounds page, whose moves have no effect of their own to lose.
            let moved = navigate(gesture)
            assert(moved == nil, "a move from a sounds page returned \(String(describing: moved))")
            presentHeldBanner()
            return stop
        }
        if case let .sounds(index) = page, gesture == .tap {
            return stopPlaying() ?? play(index, sounds: sounds(stack.candidates[index].species))
        }
        let effect = navigate(gesture)
        presentHeldBanner()
        return effect
    }

    /// The page map's moves. A tap on a sounds page is the play control, handled by `apply`.
    private mutating func navigate(_ gesture: LensGesture) -> LensEffect? {
        switch (page, gesture) {
        case (.list, .swipeDown):
            if captureRowSelected {
                // Back onto the first bird, as before any swipe: the highlight follows row one.
                captureRowSelected = false
            } else {
                pin(rowOffset: 1)
            }
        case (.list, .swipeUp):
            if !captureRowSelected { pin(rowOffset: -1) }
        case (.list, .tap), (.list, .swipeLeft):
            if isCaptureRowHighlighted {
                page = .captureViewfinder
                return .openCaptureViewfinder
            }
            page = .species(index: selection)
        case (.list, .swipeRight):
            pinnedSpecies = nil
            captureRowSelected = false
        case (.list, .back):
            return .endSession

        case let (.species(index), .swipeLeft), let (.details(index), .swipeLeft), let (.sounds(index), .swipeLeft):
            if index + 1 < stack.count { open(index + 1) }
        case (.species, .swipeRight), (.species, .back), (.details, .swipeRight), (.details, .back),
             (.sounds, .swipeRight), (.sounds, .back):
            page = .list
        case let (.species(index), .swipeDown):
            page = .details(index: index)
        case let (.species(index), .swipeUp):
            page = .sounds(index: index)
        case (.species, .tap):
            break
        case let (.details(index), .swipeUp), let (.sounds(index), .swipeDown):
            page = .species(index: index)
        case (.details, .swipeDown), (.sounds, .swipeUp), (.sounds, .tap):
            break
        case let (.details(index), .tap):
            return openViewfinder(index)

        case let (.viewfinder(index), .tap):
            return save(index, photo: true)
        case let (.viewfinder(index), _):
            return save(index, photo: false)

        case (.captureViewfinder, .tap):
            captures += 1
            awaitedCapture = captures
            page = .captureSaving
            return .capturePhoto(captures)
        case (.captureViewfinder, _):
            page = .list
        case (.captureSaving, .swipeRight), (.captureSaving, .back),
             (.captureSaved, .swipeRight), (.captureSaved, .back), (.captureSaved, .tap):
            page = .list
        case (.captureSaving, .tap), (.captureSaving, .swipeLeft), (.captureSaving, .swipeUp), (.captureSaving, .swipeDown),
             (.captureSaved, .swipeLeft), (.captureSaved, .swipeUp), (.captureSaved, .swipeDown):
            break

        case (.captureNaming, .tap):
            // "Name it later": the photo waits on the phone.
            naming = nil
            page = .captureSaved
        case (.captureNaming, .swipeRight), (.captureNaming, .back):
            naming = nil
            page = .list
        case (.captureNaming, .swipeLeft), (.captureNaming, .swipeUp), (.captureNaming, .swipeDown):
            break

        case (.captureMatches, _) where naming?.isNaming != false:
            // The chosen bird's sighting is being written (or there is nothing to choose from): nothing moves.
            break
        case (.captureMatches, .swipeDown):
            if let naming { self.naming?.highlight = min(naming.highlight + 1, naming.rows - 1) }
        case (.captureMatches, .swipeUp):
            if let naming { self.naming?.highlight = max(naming.highlight - 1, 0) }
        case (.captureMatches, .tap):
            guard let naming else { break }
            switch naming.choice {
            case .match(let match):
                self.naming?.isNaming = true
                return .nameCapture(naming.capture, as: match)
            case .again:
                return listenForName(of: naming.capture)
            case .later:
                self.naming = nil
                page = .captureSaved
            }
        case (.captureMatches, .swipeRight), (.captureMatches, .back):
            naming = nil
            page = .list
        case (.captureMatches, .swipeLeft):
            break

        case (.captureAdded, .tap), (.captureAdded, .swipeRight), (.captureAdded, .back):
            named = nil
            page = .list
        case (.captureAdded, .swipeLeft), (.captureAdded, .swipeUp), (.captureAdded, .swipeDown):
            break

        case (.problem, .swipeRight), (.problem, .back), (.problem, .tap):
            page = coveredPage
        case (.problem, .swipeLeft), (.problem, .swipeUp), (.problem, .swipeDown):
            break

        case (.friend, .swipeRight), (.friend, .back), (.friend, .tap):
            page = coveredPage
        case (.friend, .swipeLeft), (.friend, .swipeUp), (.friend, .swipeDown):
            break
        }
        return nil
    }

    /// A tap on a card element, delivered by the Display: the Add button on its own details page opens the
    /// viewfinder. Anything else is ignored.
    public mutating func press(_ action: LensAction) -> LensEffect? {
        switch (page, action) {
        case let (.details(index), .save):
            return openViewfinder(index)
        case (.list, .save), (.species, .save), (.sounds, .save), (.viewfinder, .save), (.captureViewfinder, .save),
             (.captureSaving, .save), (.captureSaved, .save), (.captureNaming, .save), (.captureMatches, .save), (.captureAdded, .save),
             (.problem, .save), (.friend, .save):
            return nil
        }
    }

    // MARK: - Friend banners

    /// A friend's notable find arrived at `time` (seconds on any steady clock; `expireBanner(at:)` takes the same
    /// one). Shown at once over the species list or a photo page, else held. It replaces the banner showing or the
    /// one held; a find already bannered this session changes nothing, even after the wearer dismissed it.
    public mutating func friendFound(_ banner: LensFriendBanner, at time: Double) {
        guard bannerIDs.insert(banner.id).inserted else { return }
        if case .friend = page {
            page = .friend(banner)
            bannerArrivedAt = time
            return
        }
        heldBanner = banner
        bannerArrivedAt = time
        presentHeldBanner()
    }

    /// Drops the held banner if it has waited more than `bannerHoldLimit` by `time`. Returns whether it did. A banner
    /// showing is left for the wearer to dismiss.
    @discardableResult
    public mutating func expireBanner(at time: Double) -> Bool {
        guard heldBanner != nil, time - bannerArrivedAt > Self.bannerHoldLimit else { return false }
        heldBanner = nil
        return true
    }

    /// The page under a friend banner showing, else the page: where the wearer is in the page map.
    public var pageUnderBanner: LensPage {
        if case .friend = page { coveredPage } else { page }
    }

    /// When the held banner is dropped, nil when none is held: the adapter wakes then to call `expireBanner(at:)`.
    public var heldBannerExpiry: Double? {
        guard heldBanner != nil, bannerArrivedAt.isFinite else { return nil }
        return bannerArrivedAt + Self.bannerHoldLimit
    }

    /// A banner the wearer already had on the lens goes back to held (a problem over it, a new session): it is shown
    /// again on the list or a photo page, however long that takes.
    private mutating func holdAgain(_ banner: LensFriendBanner) {
        heldBanner = banner
        bannerArrivedAt = .infinity
    }

    /// Shows the held banner if the wearer is on the list or a photo page.
    private mutating func presentHeldBanner() {
        guard let banner = heldBanner else { return }
        switch page {
        case .list, .species:
            coveredPage = page
            page = .friend(banner)
            heldBanner = nil
        case .details, .sounds, .viewfinder, .captureViewfinder, .captureSaving, .captureSaved, .captureNaming, .captureMatches,
             .captureAdded, .problem, .friend:
            break
        }
    }

    // MARK: - Cards

    /// The sighting an add of `species` wrote has earned `patch`. Returns whether the species is on the stack: a
    /// write that lands after the stack was replaced (a new session) is dropped.
    @discardableResult
    public mutating func earned(_ patch: LensEarnedPatch, for species: Species) -> Bool {
        guard let index = stack.candidates.firstIndex(where: { $0.species == species }) else { return false }
        earnedPatches[index] = patch
        return true
    }

    // MARK: - Captures

    /// The photo of capture `id` is written, as an unnamed sighting on the phone: the moment the photo is safe. With
    /// `dictation`, the glasses can hear the bird's name (issue #194): the page waiting for the photo becomes "Say the
    /// bird's name" and the adapter is told to listen. Without it, or when a problem page covers the wait, the saved page
    /// is where the wait ends ("Photo saved. Name it on your phone."). Nothing changes if the wearer has left the wait, or
    /// took another photo since.
    public mutating func captureSaved(_ id: Int, dictation: Bool) -> LensEffect? {
        guard awaitedCapture == id else { return nil }
        awaitedCapture = nil
        if dictation, page == .captureSaving { return listenForName(of: id) }
        endWait(on: .captureSaved)
        return nil
    }

    /// Capture `id` took no photo, or it could not be written: a problem page says so, over the list if the wearer was
    /// waiting for it, else over the page they have moved on to.
    @discardableResult
    public mutating func captureFailed(_ id: Int) -> LensEffect? {
        if awaitedCapture == id {
            awaitedCapture = nil
            endWait(on: .list)
        }
        return report(.photoNotTaken)
    }

    /// Replaces the "Saving the photo…" page, showing or under a problem page, with `next`. Returns whether the page the
    /// wearer sees changed.
    @discardableResult
    private mutating func endWait(on next: LensPage) -> Bool {
        if page == .captureSaving {
            page = next
            return true
        }
        if case .problem = page, coveredPage == .captureSaving { coveredPage = next }
        return false
    }

    // MARK: - Saying the bird's name

    /// Opens "Say the bird's name" for capture `id` with nothing heard yet, as a new dictation.
    private mutating func listenForName(of id: Int) -> LensEffect {
        dictations += 1
        naming = LensNaming(capture: id, dictation: dictations)
        page = .captureNaming
        return .listenForName(dictation: dictations, capture: id)
    }

    /// The dictation the lens is listening to, if `dictation` is it: on "Say the bird's name", with nothing covering it.
    private func listening(to dictation: Int) -> LensNaming? {
        guard page == .captureNaming, let naming, naming.dictation == dictation else { return nil }
        return naming
    }

    /// Words heard so far in dictation `dictation`, not yet final: the page shows them. Returns whether it changed.
    @discardableResult
    public mutating func heard(_ words: String, dictation: Int) -> Bool {
        guard let naming = listening(to: dictation), naming.heard != words else { return false }
        self.naming?.heard = words
        return true
    }

    /// The final words of dictation `dictation` and the birds they may name, the closest first: the lens lists them, the
    /// first highlighted, above "Say it again" and "Name it later"; with no bird, it says so and "Say it again" is
    /// highlighted. Returns whether the page changed: the words of a dictation the wearer has left are dropped.
    @discardableResult
    public mutating func matched(_ words: String, _ matches: [LensNameMatch], dictation: Int) -> Bool {
        guard listening(to: dictation) != nil else { return false }
        naming?.heard = words
        naming?.matches = Array(matches.prefix(LensNaming.matchLimit))
        naming?.highlight = 0
        page = .captureMatches
        return true
    }

    /// Dictation `dictation` ended with nothing to match: silence past the limit, a Speech error, no Speech on the
    /// glasses. The photo is saved and the lens says so. Returns whether the page changed.
    @discardableResult
    public mutating func dictationEnded(_ dictation: Int) -> Bool {
        guard listening(to: dictation) != nil else { return false }
        naming = nil
        page = .captureSaved
        return true
    }

    /// The chosen bird's sighting is written for capture `id`: the lens says "Added" and what it earned. Returns whether
    /// the page the wearer sees changed.
    @discardableResult
    public mutating func captureNamed(_ id: Int, as named: LensNamedCapture) -> Bool {
        guard endNaming(of: id, on: .captureAdded) else { return false }
        self.named = named
        return page == .captureAdded
    }

    /// The chosen bird's sighting could not be written for capture `id`: the photo is still saved, unnamed, and the lens
    /// says that. Returns whether the page the wearer sees changed.
    @discardableResult
    public mutating func captureNotNamed(_ id: Int) -> Bool {
        endNaming(of: id, on: .captureSaved) && page == .captureSaved
    }

    /// The photo of capture `id` was no longer there to name when its bird was chosen: the phone had named or deleted it.
    /// The lens says so over the list, and never that the photo waits on the phone. Returns whether the page the wearer
    /// sees changed.
    @discardableResult
    public mutating func captureGone(_ id: Int) -> Bool {
        guard endNaming(of: id, on: .list) else { return false }
        report(.photoGone)
        return true
    }

    /// Replaces the birds' page of capture `id`, showing or under a problem page, with `next`, if a bird of it was
    /// chosen. Returns whether it was.
    private mutating func endNaming(of id: Int, on next: LensPage) -> Bool {
        guard let naming, naming.capture == id, naming.isNaming else { return false }
        if page == .captureMatches {
            page = next
        } else if case .problem = page, coveredPage == .captureMatches {
            coveredPage = next
        } else {
            return false
        }
        self.naming = nil
        return true
    }

    // MARK: - Reference clips

    /// The clip `id` ended on its own (or failed to start). Returns whether it was the one playing.
    @discardableResult
    public mutating func soundEnded(_ id: Int) -> Bool {
        guard playing?.id == id else { return false }
        playing = nil
        return true
    }

    /// The clip `id` is playing on the phone, the glasses' speakers not being the route. Returns whether it was the
    /// one playing.
    @discardableResult
    public mutating func soundPlaysOnPhone(_ id: Int) -> Bool {
        guard playing?.id == id else { return false }
        playing?.onPhone = true
        return true
    }

    private mutating func play(_ index: Int, sounds: [LensSound]) -> LensEffect? {
        guard !sounds.isEmpty else { return nil }
        let position = (nextSounds[index] ?? 0) % sounds.count
        nextSounds[index] = (position + 1) % sounds.count
        playbacks += 1
        let playback = LensPlayback(id: playbacks, index: index, sound: sounds[position], onPhone: false)
        playing = playback
        return .playSound(stack.candidates[index], playback)
    }

    private mutating func stopPlaying() -> LensEffect? {
        guard playing != nil else { return nil }
        playing = nil
        return .stopSound
    }

    /// Pins the highlight to the species `rowOffset` rows from the highlighted one in list order; nothing past the
    /// ends of the list.
    private mutating func pin(rowOffset: Int) {
        guard let position = order.position(of: selection) else { return }
        let target = position + rowOffset
        if target == -1 {
            // Above the first bird is the capture row; the highlight there is on no bird.
            captureRowSelected = true
            pinnedSpecies = nil
            return
        }
        guard order.indices.indices.contains(target) else { return }
        pinnedSpecies = stack.candidates[order.indices[target]].species
    }

    private mutating func open(_ index: Int) {
        page = .species(index: index)
        pinnedSpecies = stack.candidates[index].species
    }

    private mutating func openViewfinder(_ index: Int) -> LensEffect {
        page = .viewfinder(index: index)
        return .openViewfinder(stack.candidates[index])
    }

    /// Adds the bird from the viewfinder, with a photo taken now or without one, and returns to its details page.
    private mutating func save(_ index: Int, photo: Bool) -> LensEffect {
        savedIndices.insert(index)
        // Until this add's sighting is written, the line names no card: not the previous add's.
        earnedPatches[index] = nil
        page = .details(index: index)
        let candidate = stack.candidates[index]
        return photo ? .takePhoto(candidate) : .saveSighting(candidate)
    }
}
