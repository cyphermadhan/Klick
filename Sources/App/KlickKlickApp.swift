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
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal Links arrive here when the app is launched
                    // from a browser/Messages tap on https://klick.arknet.click/join...
                    if let url = activity.webpageURL {
                        handleIncomingURL(url)
                    }
                }
        }
    }

    /// Handle channel invite deep links. Accepts two forms:
    ///   • `klick://join?payload=...` — custom URL scheme (legacy / QR codes).
    ///   • `https://klick.arknet.click/join?payload=...` — Universal Link.
    /// Both carry the same base64url-encoded payload and dispatch to the
    /// same notification, so downstream join logic doesn't fork.
    private func handleIncomingURL(_ url: URL) {
        let isCustomScheme = url.scheme == "klick" && url.host == "join"
        let isUniversalLink = (url.scheme == "https" || url.scheme == "http")
            && url.host == "klick.arknet.click"
            && url.path == "/join"
        guard isCustomScheme || isUniversalLink else { return }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payloadItem = components.queryItems?.first(where: { $0.name == "payload" }),
              let payload = payloadItem.value else { return }

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
