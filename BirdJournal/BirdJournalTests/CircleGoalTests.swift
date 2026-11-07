import Foundation
import Testing
@testable import BirdJournal

// Issue #65: goals over HTTP (the list, a custom goal made and deleted, the refusals), what the goal card says, and the
// store over the fake (the monthly goal, progress counting distinct species, a delete reducing it, who may delete).

private let api = URL(string: "https://api.example.com")!

private func http(_ status: Int, _ json: String) -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: api, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private final class Recorder {
    var requests: [URLRequest] = []
    var responses: [(Data, URLResponse)] = []

    func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return responses.isEmpty ? http(500, "{}") : responses.removeFirst()
    }
}

private let monthlyJSON = """
{"id":"monthly-2026-11","kind":"monthly","title":"November goal","target":14,"start_date":"2026-11-01",
 "end_date":"2026-11-30","starts_at":"2026-11-01T07:00:00Z","ends_at":"2026-12-01T08:00:00Z","progress":9,
 "status":"active","completed_at":null,"created_by":null,"can_delete":false}
"""

private let customJSON = """
{"id":"g-1","kind":"custom","title":"Big Day","target":3,"start_date":"2026-11-07","end_date":"2026-11-07",
 "starts_at":"2026-11-07T08:00:00Z","ends_at":"2026-11-08T08:00:00Z","progress":3,"status":"upcoming",
 "completed_at":"2026-11-07T17:00:00Z","created_by":{"id":"maya","display_name":"Maya Ortiz"},"can_delete":true}
"""

private func goal(
    kind: CircleGoal.Kind = .custom, progress: Int = 3, target: Int = 10, status: CircleGoal.Status = .active,
    start: String = "2026-11-03", end: String = "2026-11-09", startsAt: Date = Date(timeIntervalSince1970: 1_793_692_800),
    endsAt: Date = Date(timeIntervalSince1970: 1_794_297_600), creator: String? = "Maya Ortiz"
) -> CircleGoal {
    CircleGoal(
        id: "g", kind: kind, title: "Shorebirds", target: target, startDate: start, endDate: end, startsAt: startsAt,
        endsAt: endsAt, progress: progress, status: status, completedAt: nil,
        createdBy: creator.map { FeedItem.Owner(id: "maya", displayName: $0) }, canDelete: false
    )
}

private func counted(_ names: [String], edition: String? = "us-ca-la") -> [CircleGoal.Species] {
    names.map { CircleGoal.Species(speciesID: "\($0)_x", scientificName: $0, commonName: "Words from a phone", edition: edition) }
}

@Suite("A goal's patches")
struct GoalPatchSlotsTests {
    private func withSpecies(_ count: Int, progress: Int? = nil) -> CircleGoal {
        var goal = goal(kind: .monthly, progress: progress ?? count, target: 14)
        goal.species = counted((0..<count).map { "bird \($0)" })
        return goal
    }

    @Test("newest first, all of them when they fit")
    func fits() {
        let slots = GoalPatchSlots(goal: withSpecies(7), places: 7)
        #expect(slots.shown.first?.scientificName == "bird 6", "the server counts earliest first, and a new bird should show")
        #expect(slots.shown.count == 7)
        #expect(slots.more == 0)
    }

    @Test("past what fits, the last place says how many more")
    func more() {
        let slots = GoalPatchSlots(goal: withSpecies(12), places: 7)
        #expect(slots.shown.count == 6)
        #expect(slots.more == 6)
    }

    @Test("the row adds up to the goal's count even if the server's list and count disagree, and doesn't crash")
    func disagreeing() {
        let short = GoalPatchSlots(goal: withSpecies(3, progress: 12), places: 7)
        #expect(short.shown.count == 3)
        #expect(short.more == 9)
        let long = GoalPatchSlots(goal: withSpecies(5, progress: 2), places: 7)
        #expect(long.shown.count == 5)
        #expect(long.more == 0)
        #expect(GoalPatchSlots(goal: withSpecies(3), places: 1).shown.isEmpty)
        #expect(GoalPatchSlots(goal: withSpecies(3), places: 1).more == 3)
        #expect(GoalPatchSlots(goal: withSpecies(3), places: 0).shown.isEmpty)
    }

    @Test("a server too old to name them, or a goal with none yet, leaves thread alone")
    func none() {
        #expect(GoalPatchSlots(goal: goal(progress: 4), places: 7) == GoalPatchSlots(goal: withSpecies(0), places: 7))
        #expect(GoalPatchSlots(goal: goal(progress: 4), places: 7).shown.isEmpty)
        #expect(GoalPatchSlots(goal: goal(progress: 4), places: 7).more == 0)
    }

    @Test("a repeat in the list is one patch")
    func repeated() {
        var goal = withSpecies(2)
        goal.species?.append(contentsOf: counted(["bird 0"]))
        #expect(GoalPatchSlots(goal: goal, places: 7).shown.map(\.scientificName).sorted() == ["bird 0", "bird 1"])
    }

    @Test("what VoiceOver says of one never uses the server's words")
    func spoken() {
        #expect(GoalWords.spokenPatch(name: "Black Phoebe", edition: "Citrus edition") == "Black Phoebe, Citrus edition patch")
        #expect(GoalWords.spokenPatch(name: "Black Phoebe", edition: nil) == "Black Phoebe, patch")
        #expect(GoalWords.spokenPatch(name: nil, edition: nil) == "A bird this iPhone can't name, patch")
    }

    @Test("the line on Listen")
    func stillToGo() {
        var goal = goal(kind: .monthly, progress: 12, target: 14)
        goal.title = "November goal"
        #expect(GoalWords.stillToGo(goal) == "is 2 birds from its November goal")
        goal.progress = 13
        #expect(GoalWords.stillToGo(goal) == "is 1 bird from its November goal")
    }
}

@Suite("Goals over HTTP")
struct GoalClientTests {
    @Test("a goal's species are read, and may be absent")
    func species() async throws {
        let recorder = Recorder()
        let withSpecies = monthlyJSON.dropLast(1) + #","species":[{"species_id":"s_x","scientific_name":"Sayornis nigricans","common_name":"Black Phoebe","edition":"us-ca-la"},{"species_id":"t_x","scientific_name":"Turdus merula","common_name":"Common Blackbird","edition":null}]}"#
        recorder.responses = [http(200, "{\"goals\":[\(withSpecies),\(customJSON)]}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let goals = try await client.goals(circleID: "c", accessToken: "t")
        #expect(goals[0].species?.map(\.scientificName) == ["Sayornis nigricans", "Turdus merula"])
        #expect(goals[0].species?.map(\.edition) == ["us-ca-la", nil])
        #expect(goals[1].species == nil, "an older server")
    }

    @Test("a circle's goals are read and decoded with their progress")
    func list() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"goals":[\#(monthlyJSON),\#(customJSON)]}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let goals = try await client.goals(circleID: "c1", accessToken: "t")

        #expect(recorder.requests.map { "\($0.httpMethod!) \($0.url!.path())" } == ["GET /v1/circles/c1/goals"])
        #expect(goals.map(\.kind) == [.monthly, .custom])
        let monthly = goals[0]
        #expect(monthly.title == "November goal" && monthly.target == 14 && monthly.progress == 9)
        #expect(!monthly.isReached && monthly.createdBy == nil && !monthly.canDelete)
        #expect(monthly.startsAt == Date(timeIntervalSince1970: 1_793_516_400))
        let custom = goals[1]
        #expect(custom.isReached && custom.status == .upcoming && custom.canDelete)
        #expect(custom.createdBy?.name == "Maya Ortiz")
        #expect(custom.completedAt != nil)
    }

    @Test("a custom goal is made with its title, target and days, and deleted by id")
    func createAndDelete() async throws {
        let recorder = Recorder()
        recorder.responses = [http(201, customJSON), http(204, "")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let draft = GoalDraft(title: "Big Day", target: 3, startDate: "2026-11-07", endDate: "2026-11-07")
        let made = try await client.createGoal(draft, circleID: "c1", accessToken: "t-2")
        try await client.deleteGoal(id: made.id, circleID: "c1", accessToken: "t-2")

        #expect(recorder.requests.map { "\($0.httpMethod!) \($0.url!.path())" } == ["POST /v1/circles/c1/goals", "DELETE /v1/circles/c1/goals/g-1"])
        let body = try #require(recorder.requests[0].httpBody)
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["title"] as? String == "Big Day")
        #expect(sent["target"] as? Int == 3)
        #expect(sent["start_date"] as? String == "2026-11-07" && sent["end_date"] as? String == "2026-11-07")
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer t-2")
    }

    @Test("a goal that isn't yours, or the monthly goal, can't be deleted; a bad goal is rejected")
    func refusals() async {
        let recorder = Recorder()
        recorder.responses = [http(403, #"{"detail":"not_allowed"}"#), http(403, #"{"detail":"automatic_goal"}"#), http(422, #"{"detail":"ends_in_the_past"}"#), http(404, #"{"detail":"not_found"}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let draft = GoalDraft(title: "Old", target: 3, startDate: "2026-10-01", endDate: "2026-10-02")
        await #expect(throws: CircleError.goalNotYours) { try await client.deleteGoal(id: "g", circleID: "c", accessToken: "t") }
        await #expect(throws: CircleError.goalNotYours) { try await client.deleteGoal(id: "monthly-2026-11", circleID: "c", accessToken: "t") }
        await #expect(throws: CircleError.rejected) { try await client.createGoal(draft, circleID: "c", accessToken: "t") }
        await #expect(throws: CircleError.notFound) { try await client.goals(circleID: "c", accessToken: "t") }
        #expect(CircleStore.message(for: CircleError.goalNotYours, doing: "delete") == "Only a goal's creator or the Guild's creator can delete it, and the monthly goal stays.")
    }
}

@Suite("The goal card's words")
struct GoalWordsTests {
    @Test("it counts species against the target and fills the bar no further than full")
    func count() {
        #expect(GoalWords.count(goal(progress: 9, target: 14)) == "9 of 14 species")
        #expect(GoalWords.count(goal(progress: 9, target: 14), short: true) == "9/14")
        #expect(GoalWords.fraction(goal(progress: 7, target: 14)) == 0.5)
        #expect(GoalWords.fraction(goal(progress: 20, target: 14)) == 1)
    }

    @Test("the monthly goal says how many species are still to discover, without a countdown, or that it's reached")
    func monthly() {
        let november = goal(kind: .monthly, progress: 9, target: 14, endsAt: Date(timeIntervalSince1970: 1_796_112_000))
        #expect(GoalWords.monthlyNote(november) == "5 still to discover")
        let lastDay = goal(kind: .monthly, progress: 23, target: 30, endsAt: .now.addingTimeInterval(3600))
        #expect(GoalWords.monthlyNote(lastDay) == "7 still to discover", "no countdown, even on the last day")
        #expect(GoalWords.count(lastDay) == "23 of 30 species")
        #expect(GoalWords.monthlyNote(goal(kind: .monthly, progress: 14, target: 14)).hasPrefix("Reached!"))
        #expect(GoalWords.monthlyNote(goal(kind: .monthly, progress: 16, target: 14)).hasPrefix("Reached!"))
    }

    @Test("the monthly goal's headline spells its target out, calmly")
    func headline() {
        #expect(GoalWords.headline(goal(kind: .monthly, progress: 23, target: 30)) == "Thirty birds, together.")
        #expect(GoalWords.headline(goal(kind: .monthly, progress: 0, target: 1)) == "One bird, together.")
        #expect(GoalWords.headline(goal(kind: .monthly, progress: 0, target: 115)) == "115 birds, together.")
    }

    @Test("a custom goal names its days in the Guild's zone, its maker, and where it stands, without a countdown")
    func custom() {
        let now = Date(timeIntervalSince1970: 1_793_692_800)
        let week = goal(progress: 3, target: 10)
        #expect(GoalWords.days(week, timeZone: "America/Los_Angeles") == "3 Nov – 9 Nov" || GoalWords.days(week, timeZone: "America/Los_Angeles") == "Nov 3 – Nov 9")
        #expect(GoalWords.customNote(week, timeZone: "America/Los_Angeles", now: now).hasSuffix("by Maya Ortiz, 7 still to discover"))
        let bigDay = goal(start: "2026-11-07", end: "2026-11-07", startsAt: Date(timeIntervalSince1970: 1_794_038_400), endsAt: Date(timeIntervalSince1970: 1_794_124_800))
        #expect(!GoalWords.days(bigDay, timeZone: "America/Los_Angeles").contains("–"), "one day, one date")
        #expect(GoalWords.customNote(goal(progress: 10, target: 10, status: .ended), timeZone: "UTC", now: now).hasSuffix("Reached"))
        #expect(GoalWords.customNote(goal(progress: 2, target: 10, status: .ended), timeZone: "UTC", now: now).hasSuffix("Ended"))
        #expect(GoalWords.customNote(goal(status: .upcoming), timeZone: "UTC", now: now).contains("starts "))
    }
}

#if DEBUG
@Suite("The goal on Listen")
@MainActor
struct GoalOnListenTests {
    private let now = Date(timeIntervalSince1970: 1_793_692_800)

    private func monthly(id: String = "monthly", progress: Int, target: Int = 14, ending: TimeInterval = 86_400) -> CircleGoal {
        var goal = goal(kind: .monthly, progress: progress, target: target, startsAt: now.addingTimeInterval(-86_400), endsAt: now.addingTimeInterval(ending), creator: nil)
        goal.id = id
        goal.title = "November goal"
        return goal
    }

    /// A store that believes it has read these, as the cache would draw them.
    private func store(_ goals: [(String, [CircleGoal])], signedIn: Bool = true) -> CircleStore {
        let circles = goals.map { CircleSummary(id: $0.0, name: "Guild \($0.0)", createdBy: "x", createdAt: now, timeZone: "UTC", memberCount: 2, isCreator: false) }
        let url = URL.temporaryDirectory.appending(path: "goal-on-listen-\(UUID().uuidString)/last-known.json")
        let cache = CircleCache(fileURL: url)
        cache.save(CircleSnapshot(circles: circles, goals: Dictionary(uniqueKeysWithValues: goals)))
        cache.finishWrites()
        return CircleStore(account: FakeAccount.session(signedIn: signedIn), client: FakeCircleClient(seeded: false), cache: cache)
    }

    @Test("it names the Guild closest to its monthly goal")
    func closest() {
        let store = store([("far", [monthly(progress: 1)]), ("near", [monthly(progress: 12)]), ("mid", [monthly(progress: 5, target: 10)])])
        #expect(store.closestGoal(now: now)?.circle.id == "near")
    }

    @Test("a tie goes to the first listed")
    func tie() {
        let store = store([("a", [monthly(progress: 12)]), ("b", [monthly(progress: 2, target: 4)])])
        #expect(store.closestGoal(now: now)?.circle.id == "a")
    }

    @Test("a custom goal, a goal reached and a month that's over don't count, even from the cache")
    func onlyRunning() {
        var custom = monthly(progress: 13)
        custom.kind = .custom
        let reached = monthly(progress: 14)
        let over = monthly(progress: 13, ending: -1)
        #expect(store([("c", [custom]), ("r", [reached]), ("o", [over])]).closestGoal(now: now) == nil)
    }

    @Test("signed out, there's no line and nothing is read")
    func signedOut() async {
        let client = FakeCircleClient(seeded: true)
        let store = CircleStore(account: FakeAccount.session(signedIn: false), client: client)
        await store.loadRunningGoals()
        #expect(store.circles.isEmpty)
        #expect(store.closestGoal() == nil)
    }

    @Test("Listen reads the list and each Guild's goals, and not again straight away")
    func reads() async throws {
        let client = FakeCircleClient(seeded: true)
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        await store.loadRunningGoals()
        let closest = try #require(store.closestGoal())
        #expect(closest.circle.name == "Sunday Group")
        let reads = client.goalReadCount
        #expect(reads == store.circles.count)
        await store.loadRunningGoals()
        #expect(client.goalReadCount == reads)
        await store.loadRunningGoals(now: .now.addingTimeInterval(600))
        #expect(client.goalReadCount == reads * 2, "a while later, again")
    }

    @Test("the line goes on sign-out")
    func clears() async {
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: FakeCircleClient(seeded: true))
        await store.loadRunningGoals()
        #expect(store.closestGoal() != nil)
        store.clear()
        #expect(store.closestGoal() == nil)
    }

    @Test("a seeded goal's species match its count, with an edition each")
    func seeded() async throws {
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: FakeCircleClient(seeded: true))
        await store.loadRunningGoals()
        let goal = try #require(store.closestGoal()?.goal)
        #expect(goal.species?.count == goal.progress)
        #expect(goal.species?.allSatisfy { $0.edition != nil } == true)
    }
}

@Suite("Goals in the store")
@MainActor
struct CircleGoalStoreTests {
    private func store(seeded: Bool, now: @escaping () -> Date = Date.init) -> (CircleStore, FakeCircleClient) {
        let client = FakeCircleClient(seeded: seeded, now: now)
        return (CircleStore(account: FakeAccount.session(signedIn: true), client: client, timeZone: { "America/Los_Angeles" }), client)
    }

    private func find(_ species: Int, at date: Date) -> FindPolicy.Find {
        var input = FindPolicyTests.input()
        input.speciesID = "Genus\(species) species_Bird \(species)"
        input.commonName = "Bird \(species)"
        input.confirmedAt = date
        return FindPolicy.find(for: input, sharing: .automatic)!
    }

    @Test("a new circle chases 10 species in its first month, and a seeded one shows its goals in order")
    func monthly() async throws {
        let (store, _) = store(seeded: true)
        await store.refresh()
        let made = try await store.create(named: "Backyard")
        await store.loadGoals(circleID: made.circle.id)
        let goals = try #require(store.goals[made.circle.id])
        #expect(goals.map(\.kind) == [.monthly])
        #expect(goals.first?.target == 10 && goals.first?.progress == 0)
        #expect(goals.first?.title.hasSuffix(" goal") == true)

        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        await store.loadGoals(circleID: sunday.id)
        let seeded = try #require(store.goals[sunday.id])
        #expect(seeded.map(\.kind) == [.monthly, .custom, .custom, .custom])
        #expect(seeded.map(\.status).dropFirst() == [.active, .upcoming, .ended])
    }

    @Test("progress counts distinct species in the period, and a delete reduces it")
    func distinct() async throws {
        let now = Date.now
        let (store, client) = store(seeded: false, now: { now })
        let circle = try await store.create(named: "Big Day").circle.id
        let ids = (0..<4).map { _ in UUID() }
        // Bird 0 twice, Bird 1, Bird 2: three species.
        for (id, species) in zip(ids, [0, 0, 1, 2]) {
            try await client.putFind(find(species, at: now.addingTimeInterval(-60)), sightingID: id, accessToken: "t")
        }
        await store.loadGoals(circleID: circle)
        #expect(store.goals[circle]?.first?.progress == 3)
        try await client.deleteFind(sightingID: ids[0], accessToken: "t")
        await store.loadGoals(circleID: circle)
        #expect(store.goals[circle]?.first?.progress == 3, "the other Bird 0 still counts")
        try await client.deleteFind(sightingID: ids[3], accessToken: "t")
        await store.loadGoals(circleID: circle)
        #expect(store.goals[circle]?.first?.progress == 2)
    }

    @Test("a custom goal is made, listed and deleted by its maker; a friend's needs the circle's creator")
    func customGoals() async throws {
        let (store, _) = store(seeded: true)
        await store.refresh()
        let days = GoalDraft.dayFormatter(TimeZone(identifier: "America/Los_Angeles")!)
        let today = days.string(from: .now)
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        let made = try await store.createGoal(GoalDraft(title: "  Warblers ", target: 8, startDate: today, endDate: today), circleID: sunday.id)
        #expect(made.title == "Warblers" && made.canDelete)
        #expect(store.goals[sunday.id]?.contains { $0.id == made.id } == true)
        try await store.deleteGoal(id: made.id, circleID: sunday.id)
        #expect(store.goals[sunday.id]?.contains { $0.id == made.id } == false)

        // Pat started Sunday Group, so may delete Maya's goal; in Family, Robin's circle, Pat may not delete the monthly.
        let maya = try #require(store.goals[sunday.id]?.first { $0.createdBy?.id == "maya" })
        #expect(maya.canDelete)
        let family = try #require(store.circles.first { $0.name == "Family" })
        await store.loadGoals(circleID: family.id)
        let monthly = try #require(store.goals[family.id]?.first)
        await #expect(throws: CircleError.goalNotYours) { try await store.deleteGoal(id: monthly.id, circleID: family.id) }

        await #expect(throws: CircleError.rejected) {
            try await store.createGoal(GoalDraft(title: "Past", target: 3, startDate: "2020-01-01", endDate: "2020-01-02"), circleID: sunday.id)
        }
        store.clear()
        #expect(store.goals.isEmpty)
    }
}
#endif
