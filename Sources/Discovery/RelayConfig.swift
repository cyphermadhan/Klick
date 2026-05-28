import Foundation
import CryptoKit

/// Configuration for the internet relay server.
/// Not actor-isolated — these are simple UserDefaults reads safe from any context.
enum RelayConfig: Sendable {
    /// Default relay URL. Replace with your deployed Cloudflare Worker URL.
    static let defaultURL = "wss://klick-relay.maddy-ax.workers.dev"

    private static let customURLKey = "klick.relay.url"

    /// The active relay URL — custom if set, otherwise the default.
    static var activeURL: String {
        if let custom = UserDefaults.standard.string(forKey: customURLKey),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return defaultURL
    }

    static var customURL: String? {
        get { UserDefaults.standard.string(forKey: customURLKey) }
        set { UserDefaults.standard.set(newValue, forKey: customURLKey) }
    }

    /// Derive a channel room ID from the channel key.
    /// SHA-256 hash of the key, hex-encoded, first 32 chars.
    /// This ensures only holders of the same key connect to the same room,
    /// without exposing the key to the relay server.
    static func roomId(forKey key: Data) -> String {
        let hash = SHA256.hash(data: key)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
