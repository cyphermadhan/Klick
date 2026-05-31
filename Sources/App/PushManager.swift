import Foundation
import UIKit
import os

/// Manages push notification registration and ping-offline-peers requests.
@MainActor
final class PushManager: NSObject, ObservableObject {
    private let log = Logger(subsystem: "world.madhans.klick", category: "PushManager")
    private var deviceToken: String?

    /// Register for remote notifications. Call once on app launch.
    func registerForPush() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from AppDelegate when APNs returns a token.
    func didRegisterToken(_ tokenData: Data) {
        deviceToken = tokenData.map { String(format: "%02x", $0) }.joined()
        log.info("APNs token: \(self.deviceToken ?? "nil", privacy: .public)")
    }

    /// Register this device's push token with the relay for a specific channel.
    func registerWithRelay(channelKey: Data, deviceName: String) {
        guard let token = deviceToken else { return }
        let roomId = RelayConfig.roomId(forKey: channelKey)
        let baseURL = RelayConfig.activeURL.replacingOccurrences(of: "wss://", with: "https://")
        guard let url = URL(string: "\(baseURL)/register") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "channelId": roomId,
            "token": token,
            "name": deviceName
        ])

        PushNetworkClient.fire(request)
    }

    /// Ping offline members of a channel.
    func pingOfflineMembers(channelKey: Data, senderName: String) {
        let roomId = RelayConfig.roomId(forKey: channelKey)
        let baseURL = RelayConfig.activeURL.replacingOccurrences(of: "wss://", with: "https://")
        guard let url = URL(string: "\(baseURL)/ping") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "channelId": roomId,
            "senderName": senderName
        ])

        PushNetworkClient.fire(request)
    }
}

/// Isolated network client that owns its own URLSession and dispatch queue.
/// Completely detached from @MainActor — avoids iOS 26 URLSession restrictions.
private enum PushNetworkClient {
    private static let queue = DispatchQueue(label: "klick.push.network", qos: .utility)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue())
    }()

    static func fire(_ request: URLRequest) {
        queue.async {
            // Use old-school semaphore-based sync call on a background queue.
            // This avoids ALL actor isolation issues — no async, no shared, no captures.
            let sem = DispatchSemaphore(value: 0)
            let task = session.dataTask(with: request) { _, _, _ in
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 10)
        }
    }
}
