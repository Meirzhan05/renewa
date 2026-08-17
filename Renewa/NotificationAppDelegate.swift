import UIKit
import UserNotifications

extension Notification.Name {
    static let renewaDeviceTokenUpdated = Notification.Name("renewaDeviceTokenUpdated")
    static let renewaOpenInboxIntelligence = Notification.Name("renewaOpenInboxIntelligence")
}

enum InboxNotificationRoute {
    static func opensInboxIntelligence(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["renewa_route"] as? String == "inbox-intelligence"
    }

    static func batchID(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["renewa_batch_id"] as? String
    }
}

final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .renewaDeviceTokenUpdated, object: token)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let values = response.notification.request.content.userInfo
        guard InboxNotificationRoute.opensInboxIntelligence(values) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .renewaOpenInboxIntelligence, object: InboxNotificationRoute.batchID(from: values))
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
