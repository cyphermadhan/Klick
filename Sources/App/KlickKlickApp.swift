import SwiftUI
import UIKit

@main
struct KlickKlickApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// App delegate for handling push notification registration callbacks.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Forward to PushManager — PTTSession owns it, but we'll post via NotificationCenter
        NotificationCenter.default.post(
            name: .didReceiveAPNsToken,
            object: deviceToken
        )
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Push not available (simulator, no entitlement, etc.) — non-fatal.
    }
}

extension Notification.Name {
    static let didReceiveAPNsToken = Notification.Name("world.madhans.klick.apnsToken")
}
