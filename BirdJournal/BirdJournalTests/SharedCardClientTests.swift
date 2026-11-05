import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #66: a card shared by hand over HTTP (the photo's upload URL, the PUT to it, the card), the feed's extras, and
// the store over the fake server: the extras in the circles chosen and nowhere else, the photo uploaded first.

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

@Suite("Shared cards over HTTP")
struct SharedCardClientTests {
    @Test("the photo's upload URL, the signed multipart POST with its fields and no token, then the card")
    func shareWithPhoto() async throws {
        let recorder = Recorder()
        recorder.responses = [
            http(201, #"{"key":"photos/ada/abcdefghijklmnopqrstuvwx.jpg","upload_url":"https://bucket.s3.amazonaws.com/","fields":{"key":"photos/ada/abcdefghijklmnopqrstuvwx.jpg","Content-Type":"image/jpeg","policy":"cG9saWN5","x-amz-signature":"sig"},"expires_at":"2026-11-01T09:45:00Z"}"#),
            http(204, ""),
            http(201, "{}"),
        ]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let upload = try await client.photoUpload(sightingID: FindPolicyTests.identifier, accessToken: "t-1")
        try await client.uploadPhoto(Data([0xFF, 0xD8, 0xFF]), to: upload)
        let card = FindPolicy.card(for: SharedCardPolicyTests.input(), choices: .init(includeNote: true, includeOriginalPhoto: true), circleIDs: ["c1"], photoKey: upload.key)
        try await client.shareCard(card, sightingID: FindPolicyTests.identifier, accessToken: "t-1")

        #expect(recorder.requests.map { "\($0.httpMethod!) \($0.url!.host()!)\($0.url!.path())" } == [
            "POST api.example.com/v1/finds/6f9619ff-8b86-d011-b42d-00c04fc964ff/photo",
            "POST bucket.s3.amazonaws.com/",
            "PUT api.example.com/v1/finds/6f9619ff-8b86-d011-b42d-00c04fc964ff/card",
        ])
        let post = recorder.requests[1]
        #expect(post.value(forHTTPHeaderField: "Authorization") == nil, "the bucket gets no access token")
        let contentType = try #require(post.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let form = String(decoding: post.httpBody ?? Data(), as: UTF8.self)
        for field in ["key", "Content-Type", "policy", "x-amz-signature"] {
            #expect(form.contains("name=\"\(field)\""), "\(field)")
        }
        // S3 ignores fields after the file, so the file goes last.
        let fileField = try #require(form.range(of: "name=\"file\""))
        #expect(form.range(of: "name=\"policy\"")!.lowerBound < fileField.lowerBound)
        let body = try #require(try JSONSerialization.jsonObject(with: recorder.requests[2].httpBody ?? Data()) as? [String: Any])
        #expect(body["circle_ids"] as? [String] == ["c1"])
        #expect((body["photo"] as? [String: String])?["key"] == "photos/ada/abcdefghijklmnopqrstuvwx.jpg")
        #expect(body["note"] as? String == "On the fence by the creek")
    }

    @Test("a refused upload fails the share")
    func refusedUpload() async throws {
        let recorder = Recorder()
        recorder.responses = [http(403, "")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let upload = PhotoUpload(key: "photos/ada/x.jpg", uploadURL: URL(string: "https://bucket.test/")!, fields: [:], expiresAt: .now)
        await #expect(throws: CircleError.server(403)) { try await client.uploadPhoto(Data(), to: upload) }
    }

    @Test("the feed decodes a shared card's extras, and none for an automatic find")
    func feedExtras() async throws {
        let recorder = Recorder()
        let item = """
        {"sighting_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","species_id":"Sayornis nigricans_Black Phoebe",
         "scientific_name":"Sayornis nigricans","common_name":"Black Phoebe","method":"seen","place":null,
         "found_at":"2026-11-01T08:15:00Z","new_patch":false,"rarity":"common","art":null,
         "owner":{"id":"maya","display_name":"Maya Ortiz"},"circle_first":false,"is_mine":false
        """
        recorder.responses = [http(200, #"{"items":[\#(item),"card":{"note":"By the creek","caption":"A small black flame","photo":{"key":"photos/maya/p.jpg","url":"https://d111.cloudfront.net/photos/maya/p.jpg"}}},\#(item),"card":null}],"next_cursor":null}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let page = try await client.feed(circleID: "c1", cursor: nil, accessToken: "t")
        #expect(page.items[0].card == FeedItem.SharedCard(note: "By the creek", caption: "A small black flame", photo: .init(key: "photos/maya/p.jpg", url: URL(string: "https://d111.cloudfront.net/photos/maya/p.jpg"))))
        #expect(page.items[1].card == nil)
        #expect(page.items[0].place == nil)
    }
}

#if DEBUG
@Suite("Shared cards in the circles")
@MainActor
struct SharedCardStoreTests {
    @Test("a card shared by hand shows its extras in the circles chosen, an automatic find elsewhere, and a later put keeps them")
    func onlyChosenCircles() async throws {
        let client = FakeCircleClient(seeded: true)
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        let family = try #require(store.circles.first { $0.name == "Family" })
        let find = try #require(FindPolicy.find(for: SharedCardPolicyTests.input(), sharing: .automatic))
        try await client.putFind(find, sightingID: FindPolicyTests.identifier, accessToken: "t")

        let choices = FindPolicy.Choices(includeNote: true, includeOriginalPhoto: true, includeCity: false)
        try await store.shareCard(sightingID: FindPolicyTests.identifier, photo: Data([1, 2, 3])) { key in
            FindPolicy.card(for: SharedCardPolicyTests.input(), choices: choices, circleIDs: [sunday.id], photoKey: key)
        }
        #expect(client.findLog.suffix(2).first?.hasPrefix("photo photos/fake-sub/") == true, "the photo goes before the card")
        await store.loadFeed(circleID: sunday.id)
        await store.loadFeed(circleID: family.id)
        let shared = try #require(store.feeds[sunday.id]?.items.first { $0.isMine })
        #expect(shared.card?.note == "On the fence by the creek")
        #expect(shared.card?.photo != nil)
        #expect(shared.place == nil, "the city was off")
        let automatic = try #require(store.feeds[family.id]?.items.first { $0.isMine })
        #expect(automatic.card == nil)
        #expect(automatic.place == "Pasadena")

        // Heard corrected to Seen by the outbox keeps the card's extras and its hidden place.
        var seen = find
        seen.method = .seen
        try await client.putFind(seen, sightingID: FindPolicyTests.identifier, accessToken: "t")
        await store.loadFeed(circleID: sunday.id)
        let corrected = try #require(store.feeds[sunday.id]?.items.first { $0.isMine })
        #expect(corrected.method == .seen)
        #expect(corrected.card?.note == "On the fence by the creek")
        #expect(corrected.place == nil)
    }

    @Test("a private birder's card reaches only the circle chosen")
    func privateBirder() async throws {
        let client = FakeCircleClient(seeded: true)
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        await store.refresh()
        let family = try #require(store.circles.first { $0.name == "Family" })
        try await store.shareCard(sightingID: FindPolicyTests.identifier, photo: nil) { key in
            FindPolicy.card(for: SharedCardPolicyTests.input(), choices: .init(), circleIDs: [family.id], photoKey: key)
        }
        for circle in store.circles {
            await store.loadFeed(circleID: circle.id)
            let mine = store.feeds[circle.id]?.items.filter(\.isMine) ?? []
            #expect(mine.count == (circle.id == family.id ? 1 : 0), "\(circle.name)")
        }
        #expect(!client.findLog.contains { $0.hasPrefix("photo") }, "no photo chosen, none uploaded")
    }

    @Test("a circle the birder isn't in is refused")
    func notMine() async throws {
        let client = FakeCircleClient(seeded: true)
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        await #expect(throws: CircleError.notFound) {
            try await store.shareCard(sightingID: UUID(), photo: nil) { key in
                FindPolicy.card(for: SharedCardPolicyTests.input(), choices: .init(), circleIDs: ["someone-elses"], photoKey: key)
            }
        }
    }
}
#endif
