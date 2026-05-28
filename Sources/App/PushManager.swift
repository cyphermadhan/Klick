import Foundation
import UIKit
import os

/// Manages push notification registration and ping-offline-peers requests.
/// Registers the APNs device token with the relay so offline members
/// can be notified when someone is waiting in the channel.
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
        let url = URL(string: "\(RelayConfig.activeURL.replacingOccurrences(of: "wss://", with: "https://"))/register")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "channelId": roomId,
            "token": token,
            "name": deviceName
        ])

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error {
                self?.log.error("Push register failed: \(error.localizedDescription, privacy: .public)")
            }
        }.resume()
    }

    /// Ping offline members of a channel — sends push notification to anyone
    /// registered but not currently connected via WebSocket.
    func pingOfflineMembers(channelKey: Data, senderName: String) {
        let roomId = RelayConfig.roomId(forKey: channelKey)
        let url = URL(string: "\(RelayConfig.activeURL.replacingOccurrences(of: "wss://", with: "https://"))/ping")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "channelId": roomId,
            "senderName": senderName
        ])

        URLSession.shared.dataTask(with: request) { [weak self] _, _, error in
            if let error {
                self?.log.error("Ping failed: \(error.localizedDescription, privacy: .public)")
            }
        }.resume()
    }
}
