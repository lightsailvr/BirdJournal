import UIKit
import UserNotifications

/// The app delegate SwiftUI's `@UIApplicationDelegateAdaptor` makes, for what only a delegate hears (issue #63): the
/// APNs token, background pushes, and notifications shown or tapped. All of it goes to the push center.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set once by the app at launch, before any push can arrive.
    static var pushes: PushCenter?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await Self.pushes?.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.pushes?.didFailToRegister(error)
    }

    /// A content-available push, in the background or the foreground: refresh the feeds, keep a notable find.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let pushes = Self.pushes else { return .noData }
        await pushes.received(userInfo)
        return .newData
    }

    /// An alert arriving while the app is open still shows as a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// The birder tapped a push: open its circle.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // The payload isn't Sendable; it crosses to the main actor as JSON.
        guard let data = try? JSONSerialization.data(withJSONObject: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            guard let userInfo = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            Task { await Self.pushes?.opened(userInfo) }
        }
    }
}
