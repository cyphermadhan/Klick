import ActivityKit
import Foundation

/// Defines the data model for the Klick Live Activity on the lock screen
/// and Dynamic Island.
struct KlickActivityAttributes: ActivityAttributes {
    /// Static context — set once when the activity starts.
    struct ContentState: Codable, Hashable {
        var channelName: String
        var isTransmitting: Bool
        var onlinePeerCount: Int
        var peerNames: String       // "ALICE · BOB" or "NO PEERS"
        var isRunning: Bool
    }
}
