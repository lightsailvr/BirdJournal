import Foundation
import LensSession
import UserNotifications

/// A friend's notable find on the lens (issue #67): the push center's `friendFinds()` (#63) delivers every notable find
/// a push brings, in the foreground or in the background through `content-available`, and each becomes a friend
/// banner on whichever lens holds a run's pages: the glasses run's, or the lens on its own (Developer tools, the mock
/// lens). A lens with no run drops it.
enum FriendBanners {
    /// Forwards every find from `finds` to the lenses `lenses` names at that moment, until the stream ends or the task
    /// is cancelled.
    static func forward(_ finds: AsyncStream<FriendFind>, to lenses: @escaping () -> [GlassesLensSession]) -> Task<Void, Never> {
        Task {
            for await find in finds {
                let banner = find.lensBanner
                for lens in lenses() { lens.friendFound(banner) }
            }
        }
    }
}

extension FriendFind {
    /// "Maya heard a Black Phoebe · Pasadena": the friend's first name (the lens has a word budget), heard or saw, the
    /// species and the place label as the find carries it (a city or "a secret spot"; none ends the line at the bird).
    var lensBanner: LensFriendBanner {
        let firstName = ownerName?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return LensFriendBanner(
            id: "\(owner)/\(sightingID)",
            friendName: firstName ?? "A friend",
            method: method == "seen" ? .saw : .heard,
            speciesName: commonName,
            place: place
        )
    }
}

#if DEBUG
extension FriendBanners {
    /// A notable push as the server sends it, Maya's Black Phoebe in Pasadena, for the Developer screen, the mock lens
    /// (`-autoMockLensFriend YES`) and the hardware checks (DAT-SETUP-CHECKLIST.md). Each call is a new find, so a
    /// second one replaces the first rather than being taken for the same find delivered twice.
    static func samplePush() -> [AnyHashable: Any] {
        ["kind": "notable", "find": [
            "owner": "developer", "owner_name": "Maya Ortiz", "sighting_id": UUID().uuidString, "species_id": "sayornis_nigricans",
            "scientific_name": "Sayornis nigricans", "common_name": "Black Phoebe", "method": "heard", "place": "Pasadena",
            "found_at": ISO8601DateFormatter().string(from: .now), "legendary": true, "rarity": NSNull(), "circle_first": false,
            "circle_ids": [String](),
        ] as [String: Any]]
    }

    /// Posts an ordinary local notification `delay` from now, for the check whether the glasses mirror the phone's
    /// notifications (DAT-SETUP-CHECKLIST.md): the delay leaves time to lock the phone or leave the app.
    static func postLocalNotification(after delay: TimeInterval) async -> String {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            return "Notifications are off for Featherguild."
        }
        let content = UNMutableNotificationContent()
        content.title = "Maya Ortiz found a Black Phoebe"
        content.body = "A local test notification · Pasadena"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "friend-banner-check-\(UUID().uuidString)", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        do {
            try await center.add(request)
            return "Posted: it shows in \(Int(delay)) s."
        } catch {
            return "Couldn't post it: \(error.localizedDescription)"
        }
    }
}
#endif
