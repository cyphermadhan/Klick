import Foundation

struct Channel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var members: [ChannelMember]
    let createdAt: Date
    /// The device name of the channel creator. Only this user can transmit
    /// when `isBroadcast` is true.
    var creatorName: String?
    /// When true, only the creator can transmit. All others are listen-only.
    var isBroadcast: Bool = false

    var displayName: String { name.uppercased() }
}

struct ChannelMember: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let addedAt: Date
    var id: String { name }
}
