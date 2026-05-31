import SwiftUI
import UIKit

@main
struct KlickKlickApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    /// Handle klick:// deep links for channel invites.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "klick", url.host == "join" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payloadItem = components.queryItems?.first(where: { $0.name == "payload" }),
              let payload = payloadItem.value else { return }

        // Post notification — ContentView's PTTSession will pick it up and join the channel.
        NotificationCenter.default.post(
            name: .didReceiveChannelInviteLink,
            object: payload
        )
    }
}

/// App delegate for handling push notification registration callbacks.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
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
    static let didReceiveChannelInviteLink = Notification.Name("world.madhans.klick.channelInvite")
}
