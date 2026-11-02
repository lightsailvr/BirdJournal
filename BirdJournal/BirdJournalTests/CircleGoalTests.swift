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

@Suite("Goals over HTTP")
struct GoalClientTests {
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
        #expect(CircleStore.message(for: CircleError.goalNotYours, doing: "delete") == "Only the goal's creator or the circle's creator can delete it.")
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

    @Test("the monthly goal says how many more and how long is left, or that it's reached")
    func monthly() {
        let now = Date(timeIntervalSince1970: 1_793_692_800) // 3 Nov 2026, 08:00 UTC
        let november = goal(kind: .monthly, progress: 9, target: 14, endsAt: Date(timeIntervalSince1970: 1_796_112_000))
        #expect(GoalWords.monthlyNote(november, now: now) == "5 more to go · 28 days left")
        let lastDay = goal(kind: .monthly, progress: 9, target: 14, endsAt: now.addingTimeInterval(3600))
        #expect(GoalWords.monthlyNote(lastDay, now: now) == "5 more to go · Last day")
        #expect(GoalWords.monthlyNote(goal(kind: .monthly, progress: 14, target: 14), now: now).hasPrefix("Reached!"))
    }

    @Test("a custom goal names its days in the circle's zone, its maker, and where it stands")
    func custom() {
        let now = Date(timeIntervalSince1970: 1_793_692_800)
        let week = goal(progress: 3, target: 10)
        #expect(GoalWords.days(week, timeZone: "America/Los_Angeles") == "3 Nov – 9 Nov" || GoalWords.days(week, timeZone: "America/Los_Angeles") == "Nov 3 – Nov 9")
        #expect(GoalWords.customNote(week, timeZone: "America/Los_Angeles", now: now).hasSuffix("by Maya Ortiz · 7 days left"))
        let bigDay = goal(start: "2026-11-07", end: "2026-11-07", startsAt: Date(timeIntervalSince1970: 1_794_038_400), endsAt: Date(timeIntervalSince1970: 1_794_124_800))
        #expect(!GoalWords.days(bigDay, timeZone: "America/Los_Angeles").contains("–"), "one day, one date")
        #expect(GoalWords.customNote(goal(progress: 10, target: 10, status: .ended), timeZone: "UTC", now: now).hasSuffix("Reached"))
        #expect(GoalWords.customNote(goal(progress: 2, target: 10, status: .ended), timeZone: "UTC", now: now).hasSuffix("Ended"))
        #expect(GoalWords.customNote(goal(status: .upcoming), timeZone: "UTC", now: now).contains("starts "))
    }
}

#if DEBUG
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
